import AppKit
import PDFKit
import SwiftUI
import DropForgeCore
import DropForgeEngines

@MainActor
final class PDFThumbnails: ObservableObject {
    @Published var images: [Int: CGImage] = [:]
    @Published var pageCount = 0
    @Published var failed = false
    let url: URL

    init(url: URL) {
        self.url = url
        let u = url
        Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: u), !doc.isLocked else {
                await MainActor.run { self.failed = true }
                return
            }
            let count = doc.pageCount
            await MainActor.run { self.pageCount = count }
            for i in 0..<count {
                guard let page = doc.page(at: i), let img = PDFEngine.render(page, dpi: 24) else { continue }
                let box = SendablePreview(image: img, size: .zero)
                await MainActor.run { self.images[i] = box.image }
            }
        }
    }

    func page(_ i: Int, dpi: Double) async -> CGImage? {
        let u = url
        let box = await Task.detached { () -> SendablePreview? in
            guard let doc = PDFDocument(url: u), let page = doc.page(at: i), let img = PDFEngine.render(page, dpi: dpi) else { return nil }
            return SendablePreview(image: img, size: .zero)
        }.value
        return box?.image
    }
}

// MARK: - Organise

struct PDFOrganizeEditor: View {
    let context: EditorContext
    @StateObject private var thumbs: PDFThumbnails
    @State private var pages: [PageOrganization.Page] = []
    @State private var selected: Int?
    @State private var error: String?

    init(context: EditorContext) {
        self.context = context
        _thumbs = StateObject(wrappedValue: PDFThumbnails(url: context.selection.items[0].url))
    }

    var body: some View {
        EditorChrome(title: "Organise pages", subtitle: context.subtitle, primaryTitle: "Save copy", error: error,
                     canApply: !pages.isEmpty, onCancel: context.cancel, onApply: { error = context.apply(.organize(PageOrganization(pages: pages))) }) {
            HStack {
                Button { move(-1) } label: { Label("Earlier", systemImage: "arrow.left") }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button { move(1) } label: { Label("Later", systemImage: "arrow.right") }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button { rotate(-1) } label: { Label("Rotate left", systemImage: "rotate.left") }
                Button { rotate(1) } label: { Label("Rotate right", systemImage: "rotate.right") }.keyboardShortcut("r", modifiers: .command)
                Button(role: .destructive) { delete() } label: { Label("Remove", systemImage: "trash") }.keyboardShortcut(.delete, modifiers: [])
                Spacer()
                Button("Restore all") { reset() }
            }
            .disabled(thumbs.pageCount == 0)
            .labelStyle(.titleAndIcon)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { position, page in
                        thumb(position: position, page: page)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 320)
            Text("\(pages.count) of \(thumbs.pageCount) pages kept. Drag thumbnails to reorder.").font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: thumbs.pageCount) { _, _ in reset() }
    }

    func thumb(position: Int, page: PageOrganization.Page) -> some View {
        VStack(spacing: 4) {
            Group {
                if let img = thumbs.images[page.sourceIndex] {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(page.rotation) * 90))
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 100, height: 120)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).stroke(selected == position ? Color.dfAccent : Color.clear, lineWidth: 3))
            Text("Page \(page.sourceIndex + 1)").font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = position }
        .draggable(String(position))
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap(Int.init), from != position, from < pages.count else { return false }
            let p = pages.remove(at: from)
            pages.insert(p, at: min(position, pages.count))
            selected = min(position, pages.count - 1)
            return true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page.sourceIndex + 1), position \(position + 1)\(page.rotation != 0 ? ", rotated" : "")")
        .accessibilityAddTraits(selected == position ? .isSelected : [])
        .accessibilityAction { selected = position }
    }

    func reset() { pages = (0..<thumbs.pageCount).map { PageOrganization.Page(sourceIndex: $0) }; selected = pages.isEmpty ? nil : 0 }

    func move(_ d: Int) {
        guard let s = selected, s + d >= 0, s + d < pages.count else { return }
        pages.swapAt(s, s + d)
        selected = s + d
    }

    func rotate(_ d: Int) {
        guard let s = selected else { return }
        pages[s].rotation = ((pages[s].rotation + d) % 4 + 4) % 4
    }

    func delete() {
        guard let s = selected, pages.count > 1 else { return }
        pages.remove(at: s)
        selected = min(s, pages.count - 1)
    }
}

// MARK: - Split

struct PDFSplitEditor: View {
    let context: EditorContext
    @StateObject private var thumbs: PDFThumbnails
    @State private var mode = 0
    @State private var n = 2
    @State private var ranges = ""
    @State private var error: String?

    init(context: EditorContext) {
        self.context = context
        _thumbs = StateObject(wrappedValue: PDFThumbnails(url: context.selection.items[0].url))
    }

    var body: some View {
        EditorChrome(title: "Split PDF", subtitle: context.subtitle, primaryTitle: "Split", error: error, canApply: true,
                     onCancel: context.cancel, onApply: apply) {
            Form {
                LabeledContent("Pages", value: thumbs.pageCount > 0 ? "\(thumbs.pageCount)" : "…")
                Picker("Split into", selection: $mode) {
                    Text("One file per page").tag(0)
                    Text("Groups of pages").tag(1)
                    Text("Custom ranges").tag(2)
                }
                .pickerStyle(.radioGroup)
                if mode == 1 { Stepper("\(n) pages per file", value: $n, in: 1...500) }
                if mode == 2 {
                    TextField("Ranges, e.g. 1-3, 4, 5-", text: $ranges).accessibilityLabel("Page ranges")
                    Text("Each range becomes one file. “5-” means page 5 to the end.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    func apply() {
        let m: PDFSplitOptions.Mode = switch mode {
        case 0: .everyPage
        case 1: .everyN(n)
        default: .ranges(ranges)
        }
        if case .ranges(let r) = m, thumbs.pageCount > 0 {
            do { _ = try InputParsing.pageRanges(r, pageCount: thumbs.pageCount) } catch {
                self.error = UserMessage.describe(error)
                return
            }
        }
        error = context.apply(.pdfSplit(PDFSplitOptions(mode: m)))
    }
}

// MARK: - Redact

struct PDFRedactEditor: View {
    let context: EditorContext
    @StateObject private var thumbs: PDFThumbnails
    @State private var pageIndex = 0
    @State private var pageImage: CGImage?
    @State private var regions: [Int: [UnitRect]] = [:]
    @State private var draft: UnitRect?
    @State private var error: String?

    init(context: EditorContext) {
        self.context = context
        _thumbs = StateObject(wrappedValue: PDFThumbnails(url: context.selection.items[0].url))
    }

    var marked: Int { regions.values.map(\.count).reduce(0, +) }

    var body: some View {
        EditorChrome(title: "Redact PDF", subtitle: context.subtitle, primaryTitle: "Save redacted copy", error: error,
                     canApply: marked > 0, onCancel: context.cancel,
                     onApply: { error = context.apply(.redact(RedactOptions(pageRegions: regions))) }) {
            HStack {
                Button { go(-1) } label: { Image(systemName: "chevron.left") }.disabled(pageIndex == 0)
                    .accessibilityLabel("Previous page").keyboardShortcut(.leftArrow, modifiers: [])
                Text("Page \(pageIndex + 1) of \(max(thumbs.pageCount, 1))").monospacedDigit()
                Button { go(1) } label: { Image(systemName: "chevron.right") }.disabled(pageIndex >= thumbs.pageCount - 1)
                    .accessibilityLabel("Next page").keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                Button("Undo on this page") { _ = regions[pageIndex]?.popLast() }.disabled((regions[pageIndex] ?? []).isEmpty)
                Text("\(marked) area\(marked == 1 ? "" : "s") marked").foregroundStyle(.secondary)
            }
            FittedImage(image: pageImage, failed: thumbs.failed) { frame in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(((regions[pageIndex] ?? []) + (draft.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, r in
                        let v = r.view(in: frame)
                        Rectangle().fill(Color.black.opacity(0.85)).frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                    draft = UnitRect.from(v.startLocation, v.location, in: frame)
                }.onEnded { _ in
                    if let d = draft { regions[pageIndex, default: []].append(d) }
                    draft = nil
                })
                .accessibilityLabel("Page \(pageIndex + 1). Drag to cover an area.")
            }
            .frame(minHeight: 360)
            Text("Marked pages are flattened into images when saved, so the covered text is really gone. Unmarked pages stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: pageIndex) { pageImage = await thumbs.page(pageIndex, dpi: 110) }
    }

    func go(_ d: Int) { pageIndex = min(max(0, pageIndex + d), max(0, thumbs.pageCount - 1)) }
}
