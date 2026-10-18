import AppKit
import DropForgeCore

/// Borderless overlay panel. Takes key focus only in keyboard mode.
final class WheelPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Shows a wheel near the pointer and reports the user's choice.
@MainActor
public final class WheelController: NSObject, NSWindowDelegate {
    public let model: WheelModel
    public let view: WheelView
    let panel: WheelPanel
    private var anchor: CGPoint = .zero
    public private(set) var dropContents: DragContents = .none

    public init(model: WheelModel, scale: CGFloat) {
        self.model = model
        view = WheelView(model: model)
        view.scale = scale
        panel = WheelPanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = view
        panel.delegate = self
        panel.setAccessibilityLabel("DropForge wheel")
        view.onDropContents = { [weak self] contents in self?.dropContents = contents }
        model.onChange = { [weak self] in self?.modelChanged() }
    }

    public var isVisible: Bool { panel.isVisible }

    /// Shows the wheel centred on `point` (screen coordinates), clamped to the visible screen area.
    public func show(at point: CGPoint, selection: Selection?) {
        anchor = point
        model.show(selection: selection)
        resize()
        let keyboard = model.mode == .keyboard
        panel.allowsKey = keyboard
        panel.ignoresMouseEvents = false
        if Tokens.Motion.reduced {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Tokens.Wheel.appearDuration
                panel.animator().alphaValue = 1
            }
        }
        if keyboard {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            panel.makeFirstResponder(view)
        }
        NSAccessibility.post(element: view, notification: .layoutChanged)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(model.category.title) wheel, \(model.segments.count) options",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    public func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func modelChanged() {
        if panel.isVisible { resize() }
        view.needsDisplay = true
        if case .hidden = model.phase { return }
        if model.phase != .visible { hide() }
    }

    func resize() {
        let size = WheelView.preferredSize(for: model.layout, scale: view.scale)
        // Keep the disc centre (not the window centre) under the pointer.
        let footer = Tokens.Wheel.footerHeight * view.scale
        let discHeight = size.height - Tokens.Wheel.headerHeight * view.scale - footer
        var frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y - footer - discHeight / 2,
                           width: size.width, height: size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, vf.minX), vf.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, vf.minY), vf.maxY - frame.height)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    public func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses a keyboard-mode wheel, like a menu.
        if model.mode == .keyboard && model.phase == .visible { model.cancel() }
    }
}
