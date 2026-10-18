import AppKit
import Carbon.HIToolbox

/// One global shortcut via the Carbon hot key API (public, needs no Accessibility or Input Monitoring permission;
/// the system delivers only this exact key combination to DropForge).
@MainActor
public final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// Default: ⌥⌘D.
    public init(keyCode: UInt32 = UInt32(kVK_ANSI_D), modifiers: UInt32 = UInt32(optionKey | cmdKey), action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4446_4F52), id: id) // "DFOR"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    public var isRegistered: Bool { ref != nil }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        HotKey.actions[id] = nil
    }
}

/// A brief, non-activating confirmation bubble ("Copied 2 paths").
@MainActor
public final class Toast {
    private static var panel: NSPanel?

    public static func show(_ text: String, near point: CGPoint? = nil) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        let size = label.intrinsicContentSize
        let frame = NSRect(x: 0, y: 0, width: size.width + 32, height: size.height + 18)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = frame.height / 2
        label.frame = NSRect(x: 16, y: 9, width: size.width, height: size.height)
        effect.addSubview(label)
        p.contentView = effect
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        p.hasShadow = true
        p.ignoresMouseEvents = true
        let anchor = point ?? NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: anchor.x - frame.width / 2, y: anchor.y + 24))
        p.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if panel === p { p.orderOut(nil); panel = nil } }
    }
}
