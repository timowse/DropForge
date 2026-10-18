import AppKit
import SwiftUI
import DropForgeCore

/// State of the list picker. Same operations as the wheels, plus unavailable ones with the reason.
@MainActor
public final class PickerModel: ObservableObject {
    @Published public private(set) var selection: Selection
    @Published public var category: OperationCategory { didSet { if oldValue != category { highlightedID = filtered.first?.id } } }
    @Published public var query: String = "" { didSet { highlightedID = filtered.first?.id } }
    @Published public var highlightedID: String?
    @Published public private(set) var resolutions: [OperationCategory: Resolution]
    public let gestures: GestureSettings

    public var onCommit: ((OperationDescriptor, Selection) -> Void)?
    public var onCancel: (() -> Void)?
    public var onShowWheel: ((Selection, OperationCategory) -> Void)?
    public var onChooseFiles: (() -> Void)?

    public init(selection: Selection, category: OperationCategory, resolver: CapabilityResolver, gestures: GestureSettings = .standard) {
        self.selection = selection
        self.category = category
        self.gestures = gestures
        resolutions = selection.isEmpty ? [:] : resolver.resolveAll(selection)
        highlightedID = filtered.first?.id
    }

    func matches(_ d: OperationDescriptor) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || d.title.localizedCaseInsensitiveContains(q) || d.shortTitle.localizedCaseInsensitiveContains(q)
    }

    public var filtered: [OperationDescriptor] {
        (resolutions[category]?.available ?? []).filter(matches)
    }

    public var unavailable: [UnavailableOperation] {
        (resolutions[category]?.unavailable ?? []).filter { matches($0.descriptor) }
    }

    public func move(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { highlightedID = nil; return }
        let i = list.firstIndex { $0.id == highlightedID } ?? -1
        let next = min(max(i + delta, 0), list.count - 1)
        highlightedID = list[next].id
    }

    public func nextCategory(reverse: Bool = false) {
        let all = OperationCategory.allCases
        let i = all.firstIndex(of: category) ?? 0
        category = all[(i + (reverse ? all.count - 1 : 1)) % all.count]
    }

    @discardableResult
    public func commit(_ id: String? = nil) -> Bool {
        guard let d = filtered.first(where: { $0.id == (id ?? highlightedID) }) else { return false }
        onCommit?(d, selection)
        return true
    }

    public func cancel() { onCancel?() }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrics.spacingM) {
            header
            Picker("Category", selection: $model.category) {
                ForEach(OperationCategory.allCases, id: \.self) { c in
                    Text(c.title + (model.gestures.modifier(for: c).map { "  \($0.symbol)" } ?? "")).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Category")
            TextField("Filter", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("Filter options")
            list
            footer
        }
        .padding(Tokens.Metrics.spacingL)
        .frame(width: Tokens.Metrics.pickerSize.width, height: Tokens.Metrics.pickerSize.height)
        .onAppear { searchFocused = true }
    }

    var header: some View {
        HStack(spacing: Tokens.Metrics.spacingM) {
            Image(systemName: model.selection.uniformKind?.symbolName ?? "square.stack")
                .font(.title2).foregroundStyle(Color.dfAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selection.isEmpty ? "Nothing selected" : model.selection.items.count == 1
                     ? model.selection.items[0].url.lastPathComponent : "\(model.selection.count) items")
                    .font(.headline).lineLimit(2).truncationMode(.middle)
                Text(model.selection.isEmpty ? "Choose files to see what DropForge can do." : model.selection.summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.selection.isEmpty {
                Button("Choose Files…") { model.onChooseFiles?() }
            } else {
                Button { model.onShowWheel?(model.selection, model.category) } label: {
                    Label("Wheel", systemImage: "circle.circle")
                }
                .help("Show these options as a wheel")
            }
        }
        .accessibilityElement(children: .contain)
    }

    var list: some View {
        ScrollViewReader { proxy in
            List {
                if model.filtered.isEmpty && model.unavailable.isEmpty {
                    Text(model.selection.isEmpty ? "No files chosen yet." : "Nothing matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.filtered) { d in
                    Button {
                        model.commit(d.id)
                    } label: {
                        HStack(spacing: Tokens.Metrics.spacingS) {
                            Image(systemName: d.symbolName).frame(width: 22)
                                .foregroundStyle(d.id == model.highlightedID ? Color.dfOnAccent : Color.dfAccent)
                            Text(d.title)
                            Spacer()
                            if d.needsEditor { Text("Options…").font(.caption).foregroundStyle(d.id == model.highlightedID ? Color.dfOnAccent.opacity(0.85) : Color.secondary) }
                        }
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .foregroundStyle(d.id == model.highlightedID ? Color.dfOnAccent : Color.primary)
                        .background(RoundedRectangle(cornerRadius: Tokens.Metrics.smallCornerRadius)
                            .fill(d.id == model.highlightedID ? Color.dfAccent : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(d.id)
                    .accessibilityLabel(d.title)
                    .accessibilityAddTraits(d.id == model.highlightedID ? .isSelected : [])
                    .accessibilityHint(d.needsEditor ? "Opens options before running" : "Runs immediately")
                }
                if !model.unavailable.isEmpty {
                    Section("Not available") {
                        ForEach(model.unavailable, id: \.descriptor.id) { u in
                            HStack(alignment: .top, spacing: Tokens.Metrics.spacingS) {
                                Image(systemName: u.descriptor.symbolName).frame(width: 22).foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(u.descriptor.title).foregroundStyle(.secondary)
                                    Text(u.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(u.descriptor.title), unavailable. \(u.reason)")
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onChange(of: model.highlightedID) { _, id in
                if let id { withAnimation(Tokens.Motion.reduced ? nil : .default) { proxy.scrollTo(id) } }
            }
        }
    }

    var footer: some View {
        Text("↑↓ choose · ↩ apply · ⇥ or \(model.gestures.tools?.symbol ?? "⌘")/\(model.gestures.actions?.symbol ?? "⌃") switch · ⎋ cancel")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// Window hosting the picker, with arrow/Enter/Escape/Tab handled even while the filter field has focus.
@MainActor
public final class PickerWindowController: NSObject, NSWindowDelegate {
    public let model: PickerModel
    let window: NSWindow
    private var monitor: Any?
    private var lastFlags: NSEvent.ModifierFlags = []

    public init(model: PickerModel) {
        self.model = model
        window = NSWindow(contentViewController: NSHostingController(rootView: PickerView(model: model)))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "DropForge"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init()
        window.delegate = self
    }

    public func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
    }

    public func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window.orderOut(nil)
    }

    func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            let now = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let fresh = now.subtracting(lastFlags)
            lastFlags = now
            for m in ModifierMapping.modifiers(from: fresh) {
                if let c = model.gestures.category(for: m), c != .convert || m != .shift {
                    model.category = c
                    return false
                }
            }
            return false
        }
        switch event.keyCode {
        case 125: model.move(1); return true
        case 126: model.move(-1); return true
        case 36, 76: return model.commit()
        case 53: model.cancel(); return true
        case 48: model.nextCategory(reverse: event.modifierFlags.contains(.shift)); return true
        default:
            if event.modifierFlags.contains(.command), let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...3).contains(n) {
                model.category = OperationCategory.allCases[n - 1]
                return true
            }
            return false
        }
    }

    public func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
