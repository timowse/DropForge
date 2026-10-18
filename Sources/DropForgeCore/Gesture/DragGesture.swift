import Foundation
import CoreGraphics

public enum Modifier: String, Sendable, CaseIterable, Codable, Hashable {
    case shift, command, control, option

    public var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        }
    }

    public var title: String {
        switch self {
        case .shift: "Shift"
        case .command: "Command"
        case .control: "Control"
        case .option: "Option"
        }
    }
}

/// Which modifier opens which wheel during a drag. `nil` disables that wheel's gesture.
public struct GestureSettings: Sendable, Hashable, Codable {
    public var convert: Modifier?
    public var tools: Modifier?
    public var actions: Modifier?

    public init(convert: Modifier? = .shift, tools: Modifier? = .command, actions: Modifier? = .control) {
        self.convert = convert
        self.tools = tools
        self.actions = actions
    }

    public static let standard = GestureSettings()

    public func modifier(for category: OperationCategory) -> Modifier? {
        switch category {
        case .convert: convert
        case .tools: tools
        case .actions: actions
        }
    }

    public func category(for modifier: Modifier) -> OperationCategory? {
        OperationCategory.allCases.first { self.modifier(for: $0) == modifier }
    }

    /// Two wheels may not share a modifier.
    public func validate() throws {
        let used = OperationCategory.allCases.compactMap(modifier(for:))
        if Set(used).count != used.count {
            throw ValidationError("Each wheel needs its own modifier key.")
        }
    }

    public mutating func set(_ modifier: Modifier?, for category: OperationCategory) {
        switch category {
        case .convert: convert = modifier
        case .tools: tools = modifier
        case .actions: actions = modifier
        }
    }
}

/// One poll of global input state. All of it is readable without Accessibility or Input Monitoring:
/// `NSEvent.pressedMouseButtons`, `NSEvent.modifierFlags`, `NSEvent.mouseLocation` and the drag pasteboard's
/// `changeCount`.
public struct InputSample: Sendable, Hashable {
    public var primaryButtonDown: Bool
    public var dragPasteboardChangeCount: Int
    public var modifiers: Set<Modifier>
    public var location: CGPoint

    public init(primaryButtonDown: Bool, dragPasteboardChangeCount: Int, modifiers: Set<Modifier>, location: CGPoint) {
        self.primaryButtonDown = primaryButtonDown
        self.dragPasteboardChangeCount = dragPasteboardChangeCount
        self.modifiers = modifiers
        self.location = location
    }
}

public enum DragGestureEvent: Sendable, Hashable {
    /// Something started a drag (the drag pasteboard changed while the button is held).
    case dragStarted
    /// A mapped modifier was newly pressed during a drag: open that wheel at the pointer.
    case open(OperationCategory, CGPoint)
    /// Another mapped modifier was pressed while a wheel is open.
    case switchTo(OperationCategory)
    /// The button was released: the drag dropped or was cancelled.
    case dragEnded
}

/// Turns input samples into wheel events.
///
/// A real drag is recognised only when the drag pasteboard changes while the primary button is down, which
/// ignores window moves, selection rectangles and scrolling. Modifiers already held when the drag starts do
/// not open a wheel; only a fresh press does.
public struct DragGestureDetector: Sendable {
    public enum State: Sendable, Hashable {
        case idle
        case pressed(baseline: Int)
        case dragging(wheel: OperationCategory?)
    }

    public var settings: GestureSettings
    public var enabled: Bool
    public private(set) var state: State = .idle
    private var lastIdleChangeCount: Int?
    private var previousModifiers: Set<Modifier> = []

    public init(settings: GestureSettings = .standard, enabled: Bool = true) {
        self.settings = settings
        self.enabled = enabled
    }

    public var isDragging: Bool {
        if case .dragging = state { return true }
        return false
    }

    public mutating func feed(_ s: InputSample) -> [DragGestureEvent] {
        var events: [DragGestureEvent] = []
        defer { previousModifiers = s.modifiers }
        switch state {
        case .idle:
            guard s.primaryButtonDown else {
                lastIdleChangeCount = s.dragPasteboardChangeCount
                return []
            }
            let baseline = lastIdleChangeCount ?? s.dragPasteboardChangeCount
            if s.dragPasteboardChangeCount != baseline {
                // The drag began between two polls.
                state = .dragging(wheel: nil)
                events.append(.dragStarted)
                // Modifiers held at this point count as "already held".
            } else {
                state = .pressed(baseline: baseline)
            }
        case .pressed(let baseline):
            if !s.primaryButtonDown {
                state = .idle
                lastIdleChangeCount = s.dragPasteboardChangeCount
            } else if s.dragPasteboardChangeCount != baseline {
                state = .dragging(wheel: nil)
                events.append(.dragStarted)
                events += modifierEvents(s, wheel: nil)
            }
        case .dragging(let wheel):
            if !s.primaryButtonDown {
                state = .idle
                lastIdleChangeCount = s.dragPasteboardChangeCount
                events.append(.dragEnded)
            } else {
                events += modifierEvents(s, wheel: wheel)
            }
        }
        return events
    }

    private mutating func modifierEvents(_ s: InputSample, wheel: OperationCategory?) -> [DragGestureEvent] {
        guard enabled else { return [] }
        let fresh = s.modifiers.subtracting(previousModifiers)
        // Fixed priority so simultaneous presses behave predictably.
        for modifier in Modifier.allCases where fresh.contains(modifier) {
            guard let category = settings.category(for: modifier) else { continue }
            if let wheel {
                if wheel != category {
                    state = .dragging(wheel: category)
                    return [.switchTo(category)]
                }
                return []
            }
            state = .dragging(wheel: category)
            return [.open(category, s.location)]
        }
        return []
    }

    /// Called when the wheel closed for another reason (drop handled, Escape).
    public mutating func wheelClosed() {
        if case .dragging = state { state = .dragging(wheel: nil) }
    }
}
