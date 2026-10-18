import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DropForgeCore

/// Temporary holding area. Keeps references only — files are never copied or moved by the shelf.
@MainActor
public final class ShelfModel: ObservableObject {
    @Published public private(set) var items: [URL] = []

    public init() {}

    public func add(_ urls: [URL]) {
        for url in urls where !items.contains(url.standardizedFileURL) {
            items.append(url.standardizedFileURL)
        }
    }

    public func remove(_ url: URL) { items.removeAll { $0 == url } }
    public func clear() { items.removeAll() }

    /// Drops entries whose files were moved or deleted meanwhile.
    public func prune() { items.removeAll { !FileManager.default.fileExists(atPath: $0.path) } }
}

/// AppKit drag source that drags every shelf item at once.
final class DragAllView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }

    override func mouseDragged(with event: NSEvent) {
        let items = urls().map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: icon.size), contents: icon)
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : .copy
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        Tokens.Palette.accent.withAlphaComponent(0.15).setFill()
        path.fill()
        Tokens.Palette.accent.setStroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
        let s = NSAttributedString(string: "Drag all", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                     .foregroundColor: Tokens.Palette.accent])
        let size = s.size()
        s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Drag all shelf items" }
}

struct DragAllHandle: NSViewRepresentable {
    let urls: () -> [URL]
    func makeNSView(context: Context) -> DragAllView {
        let v = DragAllView()
        v.urls = urls
        return v
    }
    func updateNSView(_ nsView: DragAllView, context: Context) { nsView.urls = urls }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: Tokens.Metrics.spacingS) {
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title).foregroundStyle(Color.dfAccent)
                    Text("Shelf is empty").font(.headline)
                    Text("Drop files here to park them, then drag them out where you need them.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.items, id: \.self) { url in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .accessibilityLabel("Remove \(url.lastPathComponent) from shelf")
                        }
                        .onDrag { NSItemProvider(object: url as NSURL) }
                        .help(url.path)
                    }
                }
                .listStyle(.inset)
                HStack {
                    DragAllHandle { model.items }.frame(height: 30)
                    Button("Clear") { model.clear() }
                }
            }
        }
        .padding(Tokens.Metrics.spacingS)
        .frame(minWidth: Tokens.Metrics.shelfSize.width, minHeight: Tokens.Metrics.shelfSize.height)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Metrics.cornerRadius).stroke(Color.dfAccent, lineWidth: targeted ? 3 : 0))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add([url]) } }
                }
            }
            return true
        }
    }
}

@MainActor
public final class ShelfController {
    public let model = ShelfModel()
    lazy var panel: NSPanel = {
        let panel = NSPanel(contentViewController: NSHostingController(rootView: ShelfView(model: model)))
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel]
        panel.title = "Shelf"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("DropForgeShelf")
        return panel
    }()

    public init() {}

    public func add(_ urls: [URL]) {
        model.add(urls)
        show()
    }

    public func show() {
        model.prune()
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameTopLeftPoint(CGPoint(x: vf.minX + 24, y: vf.maxY - 24))
        }
        panel.orderFrontRegardless()
    }

    public var isVisible: Bool { panel.isVisible }
}
