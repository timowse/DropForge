import AppKit
import Combine
import DropForgeCore

/// One row in the progress window.
@MainActor
public final class UnitRow: ObservableObject, Identifiable {
    public enum Status: Equatable {
        case queued, running, succeeded, skipped, failed, cancelled
    }
    public let id: Int
    public let title: String
    @Published public var status: Status
    @Published public var progress: Double = 0
    @Published public var outputs: [URL] = []
    @Published public var message: String?

    init(_ unit: PlannedUnit) {
        id = unit.id
        title = unit.title
        status = unit.skipReason == nil ? .queued : .skipped
        message = unit.skipReason
    }
}

@MainActor
public final class JobRecord: ObservableObject, Identifiable {
    public let id = UUID()
    public let title: String
    public let operationID: String
    public let rows: [UnitRow]
    @Published public private(set) var isFinished = false
    @Published public private(set) var wasCancelled = false
    var task: Task<Void, Never>?

    init(plan: JobPlan) {
        title = plan.operation.title
        operationID = plan.operation.id
        rows = plan.units.map(UnitRow.init)
    }

    public var overallProgress: Double {
        guard !rows.isEmpty else { return 1 }
        return rows.map { r in
            switch r.status {
            case .succeeded, .skipped, .failed, .cancelled: 1
            default: r.progress
            }
        }.reduce(0, +) / Double(rows.count)
    }

    public var outputs: [URL] { rows.flatMap(\.outputs) }
    public var failures: [UnitRow] { rows.filter { $0.status == .failed } }
    public var succeededCount: Int { rows.filter { $0.status == .succeeded }.count }

    public var summary: String {
        if !isFinished {
            let done = rows.filter { [.succeeded, .skipped, .failed, .cancelled].contains($0.status) }.count
            return "\(done) of \(rows.count) done"
        }
        var parts: [String] = []
        if succeededCount > 0 { parts.append("\(succeededCount) finished") }
        let skipped = rows.filter { $0.status == .skipped }.count
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        let cancelled = rows.filter { $0.status == .cancelled }.count
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.joined(separator: " · ")
    }

    public func cancel() {
        guard !isFinished else { return }
        wasCancelled = true
        task?.cancel()
    }

    func apply(_ event: JobEvent) {
        switch event {
        case .unitStarted(let i):
            row(i)?.status = .running
        case .unitProgress(let i, let f):
            if let r = row(i), r.status == .running || r.status == .queued {
                r.status = .running
                r.progress = max(r.progress, f)
            }
        case .unitFinished(let i, let outcome):
            guard let r = row(i) else { return }
            switch outcome {
            case .succeeded(let urls, let note):
                r.status = .succeeded; r.progress = 1; r.outputs = urls; r.message = note
            case .skipped(let why):
                r.status = .skipped; r.message = why
            case .failed(let why):
                r.status = .failed; r.message = why
            case .cancelled:
                r.status = .cancelled; r.message = "Cancelled. Nothing was saved."
            }
        case .jobFinished:
            // Units that never started (cancelled before their turn).
            for r in rows where r.status == .queued || r.status == .running {
                r.status = .cancelled
                r.message = "Cancelled. Nothing was saved."
            }
            isFinished = true
        }
        objectWillChange.send()
    }

    func row(_ i: Int) -> UnitRow? { rows.first { $0.id == i } }
}

/// Owns running jobs. Events from worker tasks hop to the main actor before touching UI state.
@MainActor
public final class JobCenter: ObservableObject {
    @Published public private(set) var jobs: [JobRecord] = []
    public var onJobStarted: ((JobRecord) -> Void)?
    public var onJobFinished: ((JobRecord) -> Void)?

    public init() {}

    public var hasRunningJobs: Bool { jobs.contains { !$0.isFinished } }

    @discardableResult
    public func start(_ plan: JobPlan, executor: JobExecutor) -> JobRecord {
        let record = JobRecord(plan: plan)
        jobs.insert(record, at: 0)
        onJobStarted?(record)
        // Events are delivered in order through a stream and applied on the main actor.
        let (stream, continuation) = AsyncStream<JobEvent>.makeStream(bufferingPolicy: .unbounded)
        record.task = Task.detached(priority: .userInitiated) {
            await executor.run(plan) { continuation.yield($0) }
            continuation.finish()
        }
        Task { @MainActor [weak self] in
            for await event in stream {
                record.apply(event)
                if event == .jobFinished { self?.onJobFinished?(record) }
            }
        }
        return record
    }

    /// Records the result of work done outside the executor (file actions, rename).
    @discardableResult
    public func record(title: String, results: [(String, UnitOutcome)]) -> JobRecord {
        let units = results.enumerated().map { PlannedUnit(id: $0.offset, title: $0.element.0, inputs: [], skipReason: nil) }
        let op = OperationDescriptor(kind: .tool(.rename), title: title, shortTitle: title, symbolName: "checkmark", engines: [.native])
        let record = JobRecord(plan: JobPlan(operation: op, parameters: .none, units: units))
        jobs.insert(record, at: 0)
        onJobStarted?(record)
        for (i, r) in results.enumerated() { record.apply(.unitFinished(i, r.1)) }
        record.apply(.jobFinished)
        onJobFinished?(record)
        return record
    }

    func appendForPreview(_ record: JobRecord) {
        jobs.insert(record, at: 0)
    }

    public func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    public func cancelAll() {
        jobs.forEach { $0.cancel() }
    }
}
