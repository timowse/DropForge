import Foundation

/// What a performer is asked to do for one unit of work.
public struct UnitRequest: Sendable {
    public let operation: OperationDescriptor
    public let inputs: [DroppedItem]
    public let parameters: ToolParameters
    public let engine: EngineRequirement

    public init(operation: OperationDescriptor, inputs: [DroppedItem], parameters: ToolParameters, engine: EngineRequirement) {
        self.operation = operation
        self.inputs = inputs
        self.parameters = parameters
        self.engine = engine
    }

    public var primary: DroppedItem { inputs[0] }
}

/// Per-unit services handed to performers.
public struct UnitContext: Sendable {
    public let workspace: JobWorkspace
    public let progress: @Sendable (Double) -> Void

    public init(workspace: JobWorkspace, progress: @escaping @Sendable (Double) -> Void) {
        self.workspace = workspace
        self.progress = progress
    }
}

/// A finished item inside the workspace, waiting to be committed under a collision-safe name.
public struct StagedOutput: Sendable, Hashable {
    public let url: URL
    public let base: String
    public let ext: String
    /// Something the user should know about this result (shown under the row).
    public let note: String?

    public init(url: URL, base: String, ext: String, note: String? = nil) {
        self.url = url
        self.base = base
        self.ext = ext
        self.note = note
    }
}

/// Engines implement this. They must only write inside `context.workspace`.
public protocol UnitPerformer: Sendable {
    func perform(_ request: UnitRequest, context: UnitContext) async throws -> [StagedOutput]
}

/// A unit's final outcome.
public enum UnitOutcome: Sendable, Hashable {
    case succeeded([URL], note: String?)
    case skipped(String)
    case failed(String)
    case cancelled

    public var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

public enum JobEvent: Sendable, Hashable {
    case unitStarted(Int)
    case unitProgress(Int, Double)
    case unitFinished(Int, UnitOutcome)
    case jobFinished
}

/// A planned unit (shown as one row in the progress window).
public struct PlannedUnit: Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let inputs: [DroppedItem]
    /// Set when the unit will not run (e.g. already in the target format).
    public let skipReason: String?

    public init(id: Int, title: String, inputs: [DroppedItem], skipReason: String?) {
        self.id = id
        self.title = title
        self.inputs = inputs
        self.skipReason = skipReason
    }
}

public struct JobPlan: Sendable {
    public let operation: OperationDescriptor
    public let parameters: ToolParameters
    public let units: [PlannedUnit]

    public init(operation: OperationDescriptor, parameters: ToolParameters, units: [PlannedUnit]) {
        self.operation = operation
        self.parameters = parameters
        self.units = units
    }
}

public enum JobPlanner {
    public static func plan(_ operation: OperationDescriptor, selection: Selection, parameters: ToolParameters) -> JobPlan {
        let units: [PlannedUnit]
        switch operation.batchMode {
        case .combined:
            let title = selection.count == 1 ? selection.items[0].url.lastPathComponent : "\(selection.count) items"
            units = [PlannedUnit(id: 0, title: title, inputs: selection.items, skipReason: nil)]
        case .perItem:
            units = selection.items.enumerated().map { i, item in
                var skip: String?
                if let out = operation.outputFormat, item.format == out {
                    skip = "Already \(out.label)."
                }
                return PlannedUnit(id: i, title: item.url.lastPathComponent, inputs: [item], skipReason: skip)
            }
        }
        return JobPlan(operation: operation, parameters: parameters, units: units)
    }
}

/// Runs a plan: bounded concurrency, staging per unit, atomic collision-safe commit, cleanup on every path.
public struct JobExecutor: Sendable {
    public let performer: UnitPerformer
    public let resolver: CapabilityResolver
    public let location: OutputLocation
    public let maxConcurrent: Int
    public let committer: OutputCommitter
    public let destinationWritable: @Sendable (URL) -> Bool

    public init(performer: UnitPerformer, resolver: CapabilityResolver, location: OutputLocation = .besideOriginal,
                maxConcurrent: Int = JobExecutor.defaultConcurrency, committer: OutputCommitter = OutputCommitter(),
                destinationWritable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }) {
        self.performer = performer
        self.resolver = resolver
        self.location = location
        self.maxConcurrent = max(1, maxConcurrent)
        self.committer = committer
        self.destinationWritable = destinationWritable
    }

    public static var defaultConcurrency: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// Runs every unit; cancelling the calling task cancels running units and marks the rest cancelled.
    public func run(_ plan: JobPlan, events: @escaping @Sendable (JobEvent) -> Void) async {
        let media = plan.operation.engines.contains(.ffmpeg) || plan.operation.engines.contains(.libreOffice)
        // Media encoders are multi-threaded already; LibreOffice allows one instance per profile.
        let limit = plan.operation.engines.contains(.libreOffice) ? 1 : (media ? max(1, maxConcurrent / 2) : maxConcurrent)
        await withTaskGroup(of: Void.self) { group in
            var iterator = plan.units.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let unit = iterator.next() else { return false }
                group.addTask { await runUnit(unit, plan: plan, events: events) }
                return true
            }
            while running < limit, addNext() { running += 1 }
            while await group.next() != nil {
                if !addNext() { running -= 1 }
            }
        }
        events(.jobFinished)
    }

    func runUnit(_ unit: PlannedUnit, plan: JobPlan, events: @escaping @Sendable (JobEvent) -> Void) async {
        if Task.isCancelled { events(.unitFinished(unit.id, .cancelled)); return }
        if let skip = unit.skipReason { events(.unitFinished(unit.id, .skipped(skip))); return }
        events(.unitStarted(unit.id))
        guard let first = unit.inputs.first,
              let engine = resolver.engine(for: plan.operation, item: first) else {
            events(.unitFinished(unit.id, .failed("No installed engine can do this.")))
            return
        }
        let (directory, usedFallback) = DestinationResolver.directory(for: first.url, location: location,
                                                                      isWritable: destinationWritable)
        let workspace: JobWorkspace
        do {
            workspace = try JobWorkspace(near: directory)
        } catch {
            events(.unitFinished(unit.id, .failed("Could not create a temporary folder: \(error.localizedDescription)")))
            return
        }
        defer { workspace.cleanup() }
        let context = UnitContext(workspace: workspace) { fraction in
            events(.unitProgress(unit.id, min(max(fraction, 0), 1)))
        }
        do {
            let request = UnitRequest(operation: plan.operation, inputs: unit.inputs, parameters: plan.parameters, engine: engine)
            let staged = try await performer.perform(request, context: context)
            try Task.checkCancellation()
            guard !staged.isEmpty else { throw ValidationError("Nothing was produced.") }
            var committed: [URL] = []
            for item in staged {
                let url = try committer.commit(item.url, into: directory, base: item.base, extension: item.ext)
                Quarantine.copy(from: first.url, to: url)
                committed.append(url)
            }
            var notes = staged.compactMap(\.note)
            if usedFallback { notes.append("The original folder is read-only, so the result was saved in Downloads/DropForge.") }
            events(.unitFinished(unit.id, .succeeded(committed, note: notes.isEmpty ? nil : notes.joined(separator: " "))))
        } catch is CancellationError {
            events(.unitFinished(unit.id, .cancelled))
        } catch ProcessError.cancelled {
            events(.unitFinished(unit.id, .cancelled))
        } catch {
            if Task.isCancelled {
                events(.unitFinished(unit.id, .cancelled))
            } else {
                events(.unitFinished(unit.id, .failed(UserMessage.describe(error))))
            }
        }
    }
}

public enum UserMessage {
    /// A plain sentence for the progress window.
    public static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription, !d.isEmpty { return d }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError: return "DropForge is not allowed to read this file."
            case NSFileWriteNoPermissionError: return "DropForge is not allowed to write in this folder."
            case NSFileWriteOutOfSpaceError: return "The disk is full."
            case NSFileReadCorruptFileError: return "The file seems to be damaged."
            default: break
            }
        }
        return ns.localizedDescription
    }
}

/// Derived files inherit the Gatekeeper quarantine flag of a downloaded original.
public enum Quarantine {
    static let name = "com.apple.quarantine"

    public static func copy(from source: URL, to target: URL) {
        let size = getxattr(source.path, name, nil, 0, 0, 0)
        guard size > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(source.path, name, &buffer, size, 0, 0) == size else { return }
        _ = setxattr(target.path, name, buffer, size, 0, 0)
    }
}
