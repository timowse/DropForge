import AppKit
import DropForgeCore

/// Menu-bar entry (S01). Files dropped on the icon open the list picker.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate {
    let coordinator: AppCoordinator
    let item: NSStatusItem

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = Self.icon()
            button.image?.isTemplate = true
            button.setAccessibilityLabel("DropForge")
            button.toolTip = "DropForge — drop files here, or drag files and tap ⇧ ⌘ ⌃"
            // The status item's window accepts file drops through its delegate.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Template icon: a ring split into three segments around a dot (drawn, not borrowed).
    static func icon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            for i in 0..<3 {
                let start = CGFloat(90 + i * 120) + 12, end = CGFloat(90 + (i + 1) * 120) - 12
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: 7, startAngle: start, endAngle: end)
                p.lineWidth = 2.2
                p.lineCapStyle = .round
                p.stroke()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = coordinator.settings
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            mi.target = self
            menu.addItem(mi)
        }
        let header = NSMenuItem(title: s.dragGesturesEnabled
                                ? "Drag files, then tap \(s.gestures.convert?.symbol ?? "–") \(s.gestures.tools?.symbol ?? "–") \(s.gestures.actions?.symbol ?? "–")"
                                : "Drag gestures are off", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        add("Choose Files…", "o", action: #selector(chooseFiles))
        add("Use Finder Selection", "d", [.command, .option], action: #selector(finderSelection))
        menu.addItem(.separator())
        add("Show Progress", action: #selector(showProgress))
        add("Show Shelf", action: #selector(showShelf))
        menu.addItem(.separator())
        add("How DropForge Works", action: #selector(showWelcome))
        add("Settings…", ",", action: #selector(showSettings))
        add("Check for Updates…", action: #selector(checkForUpdates))
        add("Quit DropForge", "q", action: #selector(quit))
    }

    @objc func chooseFiles() { coordinator.chooseFilesAndOpenPicker() }
    @objc func finderSelection() { coordinator.openFinderSelection() }
    @objc func showProgress() { coordinator.progress.show() }
    @objc func showShelf() { coordinator.shelf.show() }
    @objc func showWelcome() { coordinator.showWelcome() }
    @objc func showSettings() { coordinator.showSettings() }
    @objc func checkForUpdates() { coordinator.checkForUpdates?() }
    @objc func quit() {
        coordinator.jobs.cancelAll()
        NSApp.terminate(nil)
    }

    // MARK: Drop on the icon

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        item.button?.highlight(true)
        return .copy
    }

    public func draggingExited(_ sender: NSDraggingInfo?) {
        item.button?.highlight(false)
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        guard case .files(let urls) = DragContents.read(sender.draggingPasteboard) else { return false }
        DispatchQueue.main.async { [coordinator] in coordinator.openPicker(selection: Selection(urls: urls)) }
        return true
    }
}

/// Finder › Quick Actions / Services › "Open in DropForge" (declared in Info.plist `NSServices`).
@MainActor
public final class ServiceProvider: NSObject {
    let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    @objc public func openInDropForge(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            error?.pointee = "No files were passed to DropForge." as NSString
            return
        }
        coordinator.openPicker(selection: Selection(urls: urls))
    }
}
