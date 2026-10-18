import Foundation

/// Which engines exist on this Mac right now.
public struct EngineAvailability: Sendable, Hashable {
    public var available: Set<EngineRequirement>

    public init(available: Set<EngineRequirement>) {
        self.available = available.union([.native])
    }

    public static let everything = EngineAvailability(available: Set(EngineRequirement.allCases))
    public static let nativeOnly = EngineAvailability(available: [.native])

    public func contains(_ engine: EngineRequirement) -> Bool { available.contains(engine) }

    /// First engine of `alternatives` that is installed.
    public func pick(_ alternatives: [EngineRequirement]) -> EngineRequirement? {
        alternatives.first(where: available.contains)
    }
}

/// What the wheel and the picker show for one category.
public struct Resolution: Sendable, Hashable {
    public let category: OperationCategory
    /// Runnable now, in display order.
    public let available: [OperationDescriptor]
    /// Exist for this selection but cannot run (missing engine, wrong item count). Shown greyed in the picker,
    /// never on the wheel.
    public let unavailable: [UnavailableOperation]

    public var isEmpty: Bool { available.isEmpty }
}

/// Applies `Catalog` to a selection and the installed engines.
public struct CapabilityResolver: Sendable {
    public var availability: EngineAvailability

    public init(availability: EngineAvailability) {
        self.availability = availability
    }

    public func resolve(_ selection: Selection, category: OperationCategory) -> Resolution {
        let candidates: [OperationDescriptor]
        switch category {
        case .convert: candidates = conversionCandidates(selection)
        case .tools: candidates = toolCandidates(selection)
        case .actions: candidates = Catalog.actionOrder.map(Catalog.action)
        }
        var available: [OperationDescriptor] = []
        var unavailable: [UnavailableOperation] = []
        for descriptor in candidates {
            if let reason = blockingReason(descriptor, selection: selection) {
                unavailable.append(UnavailableOperation(descriptor: descriptor, reason: reason))
            } else {
                available.append(descriptor)
            }
        }
        return Resolution(category: category, available: available, unavailable: unavailable)
    }

    /// All three categories at once.
    public func resolveAll(_ selection: Selection) -> [OperationCategory: Resolution] {
        Dictionary(uniqueKeysWithValues: OperationCategory.allCases.map { ($0, resolve(selection, category: $0)) })
    }

    /// The engine that would run `descriptor` for `item`, if any.
    public func engine(for descriptor: OperationDescriptor, item: DroppedItem) -> EngineRequirement? {
        switch descriptor.kind {
        case .convert(let target):
            return availability.pick(Catalog.engines(from: item.isDirectory ? nil : item.format, to: target))
        default:
            return availability.pick(descriptor.engines)
        }
    }

    // MARK: - Candidates

    func conversionCandidates(_ selection: Selection) -> [OperationDescriptor] {
        guard !selection.isEmpty else { return [] }
        let containsLooseItems = selection.items.contains { $0.isDirectory || $0.format == nil }
        var ordered: [ConversionTarget] = []
        var common: Set<ConversionTarget>?
        for item in selection.items {
            let source = item.isDirectory ? nil : item.format
            var reachable = Catalog.conversionTargets(for: source)
            // An item already in the target format can join a batch (it is skipped at run time).
            if let source, !source.isInputOnly, source.kind != .archive { reachable.append(.format(source)) }
            if ordered.isEmpty { ordered = reachable }
            common = common.map { $0.intersection(reachable) } ?? Set(reachable)
        }
        var targets = ordered.filter { common?.contains($0) ?? false }
        // Drop targets every item already has.
        targets.removeAll { target in
            guard case .format(let f) = target else { return false }
            return selection.items.allSatisfy { $0.format == f }
        }
        let archiveTargets: [ConversionTarget] = Catalog.archiveTargets.map { .format($0) }
        if selection.isMixed || containsLooseItems || targets.isEmpty {
            for t in archiveTargets where !targets.contains(t) { targets.append(t) }
        }
        let firstSource = selection.items.first.flatMap { $0.isDirectory ? nil : $0.format }
        return targets.map { target in
            let isArchive: Bool = { if case .format(let f) = target { return f.kind == .archive } ; return false }()
            let allArchives = selection.items.allSatisfy { $0.kind == .archive }
            // Archiving several things makes one archive; converting archives repacks each one.
            let combined = selection.isMulti && isArchive && !allArchives
            return Catalog.conversionDescriptor(target, source: allArchives ? firstSource : (isArchive ? nil : firstSource),
                                                combined: combined)
        }
    }

    func toolCandidates(_ selection: Selection) -> [OperationDescriptor] {
        guard !selection.isEmpty else { return [] }
        let kinds = selection.items.map(\.kind)
        var ordered = Catalog.tools(for: kinds[0])
        for kind in kinds.dropFirst() {
            let other = Set(Catalog.tools(for: kind))
            ordered = ordered.filter(other.contains)
        }
        return ordered.map(Catalog.tool)
    }

    // MARK: - Rules

    public func blockingReason(_ descriptor: OperationDescriptor, selection: Selection) -> String? {
        if selection.count < descriptor.minItems {
            return "Needs at least \(descriptor.minItems) files."
        }
        if let max = descriptor.maxItems, selection.count > max {
            return max == 1 ? "Works on one file at a time." : "Works on up to \(max) files."
        }
        if case .tool(let tool) = descriptor.kind {
            switch tool {
            case .merge where !selection.items.allSatisfy({ $0.kind == .pdf }):
                return "Only PDFs can be merged."
            case .join:
                guard let kind = selection.uniformKind, kind == .video || kind == .audio else {
                    return "Join needs files of one kind: all videos or all audio."
                }
            case .collage, .imagesToPDF:
                if !selection.items.allSatisfy({ $0.kind == .image }) { return "Only images can be combined." }
            default: break
            }
        }
        switch descriptor.kind {
        case .convert:
            for item in selection.items where engine(for: descriptor, item: item) == nil {
                let needed = Catalog.engines(from: item.isDirectory ? nil : item.format,
                                             to: { if case .convert(let t) = descriptor.kind { return t } ; return .extract }())
                return needed.first.map(\.missingExplanation) ?? "Not available."
            }
            return nil
        default:
            if availability.pick(descriptor.engines) == nil {
                return descriptor.engines.first?.missingExplanation ?? "Not available."
            }
            return nil
        }
    }
}
