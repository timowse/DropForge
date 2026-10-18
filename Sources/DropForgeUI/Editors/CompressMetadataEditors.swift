import AppKit
import SwiftUI
import DropForgeCore
import DropForgeEngines

// MARK: - Compress (S09)

struct CompressEditor: View {
    let context: EditorContext
    @State private var mode = 0
    @State private var preset: CompressOptions.Preset = .balanced
    @State private var percent = 50.0
    @State private var targetText = ""
    @State private var limitSize = false
    @State private var maxDimension = 1920
    @State private var error: String?

    var kind: FileKind { context.selection.uniformKind ?? .other }
    var total: Int64 { context.selection.totalBytes }

    var body: some View {
        EditorChrome(title: "Compress", subtitle: context.subtitle, primaryTitle: "Compress", error: error, canApply: true,
                     onCancel: context.cancel, onApply: apply) {
            Form {
                LabeledContent("Current size", value: ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                Picker("Method", selection: $mode) {
                    Text("Preset").tag(0)
                    Text("Percentage").tag(1)
                    Text("Target size").tag(2)
                }
                .pickerStyle(.segmented)
                switch mode {
                case 0:
                    Picker("Quality", selection: $preset) {
                        ForEach(CompressOptions.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                case 1:
                    Slider(value: $percent, in: 10...90, step: 5) {
                        Text("Aim for \(Int(percent)) % of the original")
                    }
                    .accessibilityValue("\(Int(percent)) percent")
                    LabeledContent("About", value: ByteCountFormatter.string(fromByteCount: Int64(Double(total) * percent / 100), countStyle: .file))
                default:
                    TextField("Target size, e.g. 2 MB or 500 KB", text: $targetText)
                        .accessibilityLabel("Target size")
                    if context.selection.isMulti {
                        Text("Each file aims for this size.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if kind == .image || kind == .video {
                    Toggle("Limit the long edge", isOn: $limitSize)
                    if limitSize {
                        Picker("Long edge", selection: $maxDimension) {
                            ForEach([480, 720, 1080, 1280, 1920, 2560, 3840], id: \.self) { Text("\($0) px").tag($0) }
                        }
                    }
                }
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
        .onAppear {
            let suggested = max(Int64(1), (context.selection.items.first?.byteSize ?? 0) / 2)
            targetText = ByteCountFormatter.string(fromByteCount: suggested, countStyle: .file)
        }
    }

    var note: String {
        switch kind {
        case .image: "PNG, TIFF, BMP and GIF without transparency are saved as JPG; transparent images stay PNG."
        case .video: "Video is re-encoded with H.264 (VP9 for WebM). Target sizes are approximate."
        case .audio: "Lossless audio (WAV, AIFF, FLAC) becomes AAC in an M4A file."
        case .pdf: "Images inside the PDF are re-compressed. If that is not enough for a target, pages are flattened to images."
        default: ""
        }
    }

    func apply() {
        let m: CompressOptions.Mode
        switch mode {
        case 0: m = .preset(preset)
        case 1: m = .percent(Int(percent))
        default:
            guard let bytes = InputParsing.byteSize(targetText) else {
                error = "Enter a size such as 2 MB, 750 KB or 1.5 GB."
                return
            }
            m = .targetBytes(bytes)
        }
        error = context.apply(.compress(CompressOptions(mode: m, maxDimension: limitSize ? maxDimension : nil)))
    }
}

// MARK: - Metadata (S10)

struct MetadataEditor: View {
    let context: EditorContext
    @State private var rows: [(String, String, String)] = []
    @State private var loading = true
    @State private var title = ""
    @State private var author = ""
    @State private var comment = ""
    @State private var keywords = ""
    @State private var removeLocation = false
    @State private var error: String?

    var body: some View {
        EditorChrome(title: "Metadata", subtitle: context.subtitle, primaryTitle: "Save edited copy", error: error, canApply: true,
                     onCancel: context.cancel, onApply: apply) {
            HStack(alignment: .top, spacing: Tokens.Metrics.spacingL) {
                VStack(alignment: .leading) {
                    Text("Current information").font(.headline)
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if rows.isEmpty {
                        Text("This file carries no readable metadata.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(rows.enumerated().map { MetaRow(id: $0.offset, group: $0.element.0, key: $0.element.1, value: $0.element.2) }) {
                            TableColumn("Group", value: \.group).width(min: 60, ideal: 80)
                            TableColumn("Field", value: \.key).width(min: 80, ideal: 140)
                            TableColumn("Value", value: \.value)
                        }
                    }
                }
                Form {
                    Section("Edit") {
                        TextField("Title", text: $title)
                        TextField("Author / artist", text: $author)
                        TextField("Comment", text: $comment)
                        TextField("Keywords (comma separated)", text: $keywords)
                        Toggle("Remove location", isOn: $removeLocation)
                    }
                    Section {
                        Button(role: .destructive) {
                            error = context.apply(.metadata(MetadataEdit(removeAll: true, removeLocation: true)))
                        } label: { Label("Save a copy without any metadata", systemImage: "eraser") }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 300)
            }
        }
        .task { await load() }
    }

    struct MetaRow: Identifiable { let id: Int; let group: String; let key: String; let value: String }

    func load() async {
        let item = context.first
        let url = item.url
        let found: [(String, String, String)]
        switch item.kind {
        case .image: found = await Task.detached { ImageEngine.metadataRows(url) }.value
        case .pdf: found = await Task.detached { PDFEngine().metadataRows(url) }.value
        case .video, .audio: found = await MediaEngine().metadataRows(url)
        default: found = []
        }
        rows = found
        loading = false
        // Pre-fill editable fields from what exists.
        func value(_ keys: [String]) -> String {
            found.first { keys.contains($0.1.lowercased()) }?.2 ?? ""
        }
        title = value(["title", "imagedescription", "title attribute", "pdfdocumenttitleattribute"])
        author = value(["artist", "author", "pdfdocumentauthorattribute"])
        comment = value(["comment", "usercomment", "pdfdocumentsubjectattribute"])
    }

    func apply() {
        func opt(_ s: String) -> String? { s }
        error = context.apply(.metadata(MetadataEdit(title: opt(title), author: opt(author), comment: opt(comment),
                                                     keywords: keywords.isEmpty ? nil : keywords, removeLocation: removeLocation)))
    }
}
