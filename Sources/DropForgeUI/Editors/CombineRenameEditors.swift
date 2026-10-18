import AppKit
import SwiftUI
import DropForgeCore
import DropForgeEngines

/// Lets the user reorder the inputs of a combining tool. Order = drop order by default.
struct OrderList: View {
    @Binding var urls: [URL]
    @State private var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            List(selection: $selected) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    Text("\(i + 1). \(url.lastPathComponent)").lineLimit(1).truncationMode(.middle).tag(i)
                }
                .onMove { from, to in urls.move(fromOffsets: from, toOffset: to) }
            }
            .frame(minHeight: 120)
            HStack {
                Button { shift(-1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move up").disabled((selected ?? 0) == 0)
                Button { shift(1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move down")
                    .disabled(selected == nil || selected! >= urls.count - 1)
                Button("Sort by name") { urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
            }
        }
    }

    func shift(_ d: Int) {
        guard let s = selected, s + d >= 0, s + d < urls.count else { return }
        urls.swapAt(s, s + d)
        selected = s + d
    }
}

struct CollageEditor: View {
    let context: EditorContext
    @State private var urls: [URL]
    @State private var options = CollageOptions()
    @State private var squareCells = true
    @State private var preview: CGImage?
    @State private var thumbs: [URL: SendablePreview] = [:]
    @State private var error: String?

    init(context: EditorContext) {
        self.context = context
        _urls = State(initialValue: context.selection.urls)
        var o = CollageOptions()
        o.columns = min(3, max(1, context.selection.count))
        _options = State(initialValue: o)
    }

    var body: some View {
        EditorChrome(title: "Collage", subtitle: "\(urls.count) images", primaryTitle: "Make collage", error: error, canApply: urls.count >= 2,
                     onCancel: context.cancel, onApply: apply) {
            HStack(alignment: .top, spacing: Tokens.Metrics.spacingL) {
                FittedImage(image: preview, failed: false) { _ in EmptyView() }
                    .frame(minWidth: 360, minHeight: 320)
                Form {
                    Stepper("Columns: \(options.columns)", value: $options.columns, in: 1...10)
                    Picker("Width", selection: $options.width) {
                        ForEach([1200, 1800, 2400, 3600, 4800], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Toggle("Square cells", isOn: $squareCells)
                    Stepper("Spacing: \(options.spacing) px", value: $options.spacing, in: 0...200, step: 4)
                    Stepper("Corners: \(options.cornerRadius) px", value: $options.cornerRadius, in: 0...200, step: 4)
                    ColorPicker("Background", selection: Binding(get: { options.background.color }, set: { options.background = RGBAColor($0) }))
                    Picker("Format", selection: $options.format) {
                        Text("JPG").tag(FileFormat.jpeg); Text("PNG").tag(FileFormat.png); Text("HEIC").tag(FileFormat.heic)
                    }
                    Section("Order") { OrderList(urls: $urls) }
                }
                .formStyle(.grouped)
                .frame(width: 300)
            }
        }
        .task { await loadThumbs() }
        .onChange(of: options) { _, _ in render() }
        .onChange(of: squareCells) { _, v in options.cellAspect = v ? 1 : nil }
        .onChange(of: urls) { _, _ in render() }
    }

    func loadThumbs() async {
        for url in urls {
            let box = await Task.detached { (try? ImageEngine().load(url, maxPixelSize: 400)).map { SendablePreview(image: $0.image, size: .zero) } }.value
            if let box { thumbs[url] = box }
        }
        render()
    }

    func render() {
        var small = options
        small.width = 900
        small.spacing = Int(Double(options.spacing) * 900 / Double(max(options.width, 1)))
        small.cornerRadius = Int(Double(options.cornerRadius) * 900 / Double(max(options.width, 1)))
        let images = urls.compactMap { thumbs[$0] }
        let o = small
        Task.detached(priority: .userInitiated) {
            let out = ImageEngine.collage(images.map(\.image), o).map { SendablePreview(image: $0, size: .zero) }
            await MainActor.run { preview = out?.image }
        }
    }

    func apply() {
        // Reordering changes the selection the job runs on.
        context.reorder(urls)
        error = context.apply(.collage(options))
    }
}

struct ImagesToPDFEditor: View {
    let context: EditorContext
    @State private var urls: [URL]
    @State private var options = ImagesToPDFOptions()
    @State private var error: String?

    init(context: EditorContext) {
        self.context = context
        _urls = State(initialValue: context.selection.urls)
    }

    var body: some View {
        EditorChrome(title: "Combine into PDF", subtitle: "\(urls.count) image\(urls.count == 1 ? "" : "s"), one per page", primaryTitle: "Make PDF",
                     error: error, canApply: !urls.isEmpty, onCancel: context.cancel, onApply: {
                         context.reorder(urls)
                         error = context.apply(.imagesToPDF(options))
                     }) {
            Form {
                Picker("Page size", selection: $options.pageSize) {
                    ForEach(ImagesToPDFOptions.PageSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if options.pageSize != .fitImage { Toggle("Landscape", isOn: $options.landscape) }
                Stepper("Margin: \(Int(options.margin)) pt", value: $options.margin, in: 0...144, step: 6)
                Section("Page order") { OrderList(urls: $urls) }
            }
            .formStyle(.grouped)
        }
    }
}

extension EditorContext {
    /// Editors that reorder inputs call this before `apply`.
    func reorder(_ urls: [URL]) {
        reorderHandler?(urls)
    }
}

// MARK: - Rename

struct RenameEditor: View {
    let context: EditorContext
    @State private var pattern = RenamePattern()
    @State private var preview: [RenamePlanItem] = []
    @State private var error: String?

    var body: some View {
        EditorChrome(title: "Rename", subtitle: context.subtitle, primaryTitle: "Rename \(context.selection.count) item\(context.selection.count == 1 ? "" : "s")",
                     error: error, canApply: preview.contains(where: \.changes), onCancel: context.cancel,
                     onApply: { error = context.apply(.rename(pattern)) }) {
            Form {
                TextField("Name pattern", text: $pattern.template).accessibilityLabel("Name pattern")
                HStack {
                    ForEach(RenamePattern.tokens, id: \.self) { t in
                        Button(t) { pattern.template += t }.controlSize(.small)
                    }
                }
                HStack {
                    TextField("Find", text: $pattern.find)
                    TextField("Replace with", text: $pattern.replace)
                    Toggle("Regex", isOn: $pattern.useRegex)
                }
                HStack {
                    Picker("Case", selection: $pattern.caseMode) {
                        Text("Keep").tag(RenamePattern.CaseMode.keep); Text("lower").tag(RenamePattern.CaseMode.lower)
                        Text("UPPER").tag(RenamePattern.CaseMode.upper); Text("Title").tag(RenamePattern.CaseMode.title)
                    }
                    Stepper("Start at \(pattern.startNumber)", value: $pattern.startNumber, in: 0...100_000)
                    Stepper("Digits \(pattern.padding)", value: $pattern.padding, in: 1...8)
                }
                TextField("Date format", text: $pattern.dateFormat)
            }
            .formStyle(.grouped)
            Table(preview.enumerated().map { RenameRow(id: $0.offset, old: $0.element.source.lastPathComponent, new: $0.element.newName) }) {
                TableColumn("Now", value: \.old)
                TableColumn("Becomes", value: \.new)
            }
            .frame(minHeight: 160)
        }
        .onAppear(perform: refresh)
        .onChange(of: pattern) { _, _ in refresh() }
    }

    struct RenameRow: Identifiable { let id: Int; let old: String; let new: String }

    func refresh() {
        do {
            preview = try RenamePlanner.plan(context.selection.urls, pattern: pattern)
            error = nil
        } catch {
            preview = []
            self.error = UserMessage.describe(error)
        }
    }
}

// MARK: - Factory

@MainActor
enum EditorFactory {
    static func view(for context: EditorContext) -> AnyView? {
        guard case .tool(let tool) = context.descriptor.kind else { return nil }
        let kind = context.selection.uniformKind
        switch tool {
        case .compress: return AnyView(CompressEditor(context: context))
        case .resize: return AnyView(ResizeEditor(context: context))
        case .crop: return AnyView(CropEditor(context: context))
        case .rotate: return AnyView(RotateEditor(context: context))
        case .adjust: return AnyView(AdjustEditor(context: context))
        case .annotate: return AnyView(AnnotateEditor(context: context))
        case .frame: return AnyView(FrameEditor(context: context))
        case .redact: return kind == .pdf ? AnyView(PDFRedactEditor(context: context)) : AnyView(RedactEditor(context: context))
        case .metadata: return AnyView(MetadataEditor(context: context))
        case .trim, .speed, .snapshot, .normalize, .channels, .bleep:
            return AnyView(MediaToolEditor(context: context, tool: tool))
        case .split: return kind == .pdf ? AnyView(PDFSplitEditor(context: context)) : AnyView(MediaToolEditor(context: context, tool: tool))
        case .organize: return AnyView(PDFOrganizeEditor(context: context))
        case .imagesToPDF: return AnyView(ImagesToPDFEditor(context: context))
        case .collage: return AnyView(CollageEditor(context: context))
        case .rename: return AnyView(RenameEditor(context: context))
        case .stripMetadata, .join, .mute, .merge, .readQR, .archive: return nil
        }
    }
}
