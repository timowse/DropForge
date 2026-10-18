import AppKit
import DropForgeCore

/// One wheel segment.
public struct WheelSegment: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case operation(OperationDescriptor)
        /// Overflow: opens the list picker with everything.
        case more(Int)
    }
    public let content: Content

    public var title: String {
        switch content {
        case .operation(let d): d.shortTitle
        case .more(let n): "\(n) more"
        }
    }

    public var symbolName: String {
        switch content {
        case .operation(let d): d.symbolName
        case .more: "ellipsis.circle"
        }
    }

    public var accessibilityLabel: String {
        switch content {
        case .operation(let d): d.title
        case .more(let n): "Show \(n) more options in a list"
        }
    }

    public var descriptor: OperationDescriptor? {
        if case .operation(let d) = content { return d }
        return nil
    }
}

/// State of the radial chooser, independent of drawing. Drives `WheelView` and is what UI tests exercise.
@MainActor
public final class WheelModel {
    public enum Mode: Equatable, Sendable {
        /// Opened during someone else's drag: the drop chooses.
        case drag
        /// Opened from the menu, a Service or the hot key: the wheel has keyboard focus.
        case keyboard
    }

    public enum Phase: Equatable, Sendable {
        case hidden
        case visible
        case committed(String)
        case cancelled
    }

    public let mode: Mode
    public private(set) var selection: Selection?
    public private(set) var category: OperationCategory
    public private(set) var resolutions: [OperationCategory: Resolution] = [:]
    public private(set) var segments: [WheelSegment] = []
    public private(set) var highlighted: Int?
    public private(set) var phase: Phase = .hidden
    public private(set) var layout = WheelLayout(count: 0)

    public var resolver: CapabilityResolver
    public var gestures: GestureSettings
    public var outputLocation: OutputLocation

    public var onCommit: ((OperationDescriptor, Selection) -> Void)?
    public var onMore: ((Selection, OperationCategory) -> Void)?
    public var onCancel: (() -> Void)?
    public var onChange: (() -> Void)?

    public init(mode: Mode, category: OperationCategory, resolver: CapabilityResolver,
                gestures: GestureSettings = .standard, outputLocation: OutputLocation = .besideOriginal) {
        self.mode = mode
        self.category = category
        self.resolver = resolver
        self.gestures = gestures
        self.outputLocation = outputLocation
    }

    // MARK: Lifecycle

    public func show(selection: Selection?) {
        phase = .visible
        setSelection(selection)
    }

    public func setSelection(_ selection: Selection?) {
        guard selection != self.selection || resolutions.isEmpty else { return }
        self.selection = selection
        if let selection, !selection.isEmpty {
            resolutions = resolver.resolveAll(selection)
        } else {
            resolutions = [:]
        }
        rebuild()
    }

    public func switchTo(_ category: OperationCategory) {
        guard category != self.category else { return }
        self.category = category
        highlighted = nil
        rebuild()
    }

    /// Tab / ⇥: cycles Convert → Tools → Actions.
    public func nextCategory(reverse: Bool = false) {
        let all = OperationCategory.allCases
        let i = all.firstIndex(of: category) ?? 0
        switchTo(all[(i + (reverse ? all.count - 1 : 1)) % all.count])
    }

    func rebuild() {
        let ops = resolutions[category]?.available ?? []
        let capacity = WheelLayout.capacity
        if ops.count > capacity {
            segments = ops.prefix(capacity - 1).map { WheelSegment(content: .operation($0)) }
                + [WheelSegment(content: .more(ops.count - (capacity - 1)))]
        } else {
            segments = ops.map { WheelSegment(content: .operation($0)) }
        }
        layout = WheelLayout(count: segments.count, hubRadius: Tokens.Wheel.hubRadius, ringWidth: Tokens.Wheel.ringWidth,
                             ringGap: Tokens.Wheel.ringGap)
        if let h = highlighted, h >= segments.count { highlighted = nil }
        if mode == .keyboard && highlighted == nil && !segments.isEmpty { highlighted = 0 }
        onChange?()
    }

    // MARK: Interaction

    public func hover(_ index: Int?) {
        let valid = index.flatMap { $0 < segments.count ? $0 : nil }
        guard valid != highlighted else { return }
        highlighted = valid
        onChange?()
    }

    public func move(_ direction: WheelLayout.Direction) {
        hover(layout.move(from: highlighted, direction))
    }

    /// Enter / click / drop on a segment.
    @discardableResult
    public func commit(index: Int? = nil) -> Bool {
        guard phase == .visible, let selection, !selection.isEmpty else { return false }
        guard let i = index ?? highlighted, i < segments.count else { return false }
        switch segments[i].content {
        case .operation(let d):
            phase = .committed(d.id)
            onChange?()
            onCommit?(d, selection)
        case .more:
            phase = .committed("more")
            onChange?()
            onMore?(selection, category)
        }
        return true
    }

    public func cancel() {
        guard phase == .visible else { return }
        phase = .cancelled
        onChange?()
        onCancel?()
    }

    /// Category for a modifier pressed while the wheel has focus.
    public func category(forModifier modifier: Modifier) -> OperationCategory? {
        gestures.category(for: modifier)
    }

    // MARK: Hub text

    public var hubTitle: String {
        guard let selection else { return "Reading items…" }
        return selection.summary
    }

    public var hubSubtitle: String {
        if selection == nil { return "Move over the wheel" }
        if segments.isEmpty {
            switch category {
            case .convert: return "No conversions for this"
            case .tools: return "No tools for this"
            case .actions: return "No actions available"
            }
        }
        if let h = highlighted { return segments[h].accessibilityLabel }
        switch category {
        case .convert: return "Choose a format"
        case .tools: return "Choose a tool"
        case .actions: return "Choose an action"
        }
    }

    /// "→ Photo.png · Desktop" for the highlighted segment.
    public var hubPreview: String? {
        guard let selection, let first = selection.items.first, let h = highlighted,
              let d = segments[h].descriptor else { return nil }
        let folderURL: URL
        switch outputLocation {
        case .besideOriginal: folderURL = first.url.deletingLastPathComponent()
        case .folder(let u): folderURL = u
        }
        let folder = FileManager.default.displayName(atPath: folderURL.path)
        switch d.kind {
        case .convert(.format(let f)):
            if d.batchMode == .combined || f.kind == .archive && selection.isMulti {
                return "→ Archive.\(f.preferredExtension) in \(folder)"
            }
            if selection.isMulti { return "→ \(selection.count) \(f.label) files next to the originals" }
            let name = OutputNaming.previewName(base: OutputNaming.baseName(for: first.url), extension: f.preferredExtension, in: folderURL)
            return "→ \(name) in \(folder)"
        case .convert(.extract):
            return "→ extracted into \(folder)"
        case .tool:
            return d.needsEditor ? "Opens options first · saves a copy in \(folder)" : "→ new copy in \(folder)"
        case .action:
            return nil
        }
    }

    /// Hint row under the header.
    public var categoryHints: [(OperationCategory, String)] {
        OperationCategory.allCases.map { c in
            let key = gestures.modifier(for: c)?.symbol ?? "–"
            return (c, "\(key) \(c.title)")
        }
    }
}
