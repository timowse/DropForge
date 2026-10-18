import AppKit
import DropForgeCore

/// Watches for file drags anywhere and modifier taps during them.
///
/// Least privilege by design: it only *reads* state that any app may read — the mouse button state, the
/// modifier state, the pointer location and the drag pasteboard's change counter — and listens to global
/// *mouse* events, which need no Accessibility or Input Monitoring permission. It never sees keystrokes.
@MainActor
public final class DragMonitor {
    public var detector: DragGestureDetector
    public var onEvent: ((DragGestureEvent) -> Void)?
    /// Injected in tests.
    public var sampler: () -> InputSample

    private var idleTimer: Timer?
    private var fastTimer: Timer?
    private var monitor: Any?
    public private(set) var isRunning = false

    public static let idleInterval: TimeInterval = 0.25
    public static let activeInterval: TimeInterval = 1.0 / 60

    public init(settings: GestureSettings, enabled: Bool = true, sampler: (() -> InputSample)? = nil) {
        detector = DragGestureDetector(settings: settings, enabled: enabled)
        let dragPasteboard = NSPasteboard(name: .drag)
        self.sampler = sampler ?? {
            InputSample(primaryButtonDown: NSEvent.pressedMouseButtons & 1 == 1,
                        dragPasteboardChangeCount: dragPasteboard.changeCount,
                        modifiers: ModifierMapping.set(from: NSEvent.modifierFlags),
                        location: NSEvent.mouseLocation)
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginFastPolling() }
        }
        let idle = Timer(timeInterval: Self.idleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTick() }
        }
        idle.tolerance = 0.1
        RunLoop.main.add(idle, forMode: .common)
        idleTimer = idle
    }

    public func stop() {
        isRunning = false
        idleTimer?.invalidate(); idleTimer = nil
        fastTimer?.invalidate(); fastTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func idleTick() {
        let s = sampler()
        if s.primaryButtonDown { beginFastPolling() } else { process(s) }
    }

    func beginFastPolling() {
        guard fastTimer == nil else { return }
        let t = Timer(timeInterval: Self.activeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        // Event tracking mode keeps the timer firing while a drag session runs the loop.
        RunLoop.main.add(t, forMode: .eventTracking)
        fastTimer = t
        fastTick()
    }

    func fastTick() {
        let s = sampler()
        process(s)
        if !s.primaryButtonDown {
            fastTimer?.invalidate()
            fastTimer = nil
        }
    }

    /// Feeds one sample (also used directly by tests).
    public func process(_ sample: InputSample) {
        for event in detector.feed(sample) { onEvent?(event) }
    }
}
