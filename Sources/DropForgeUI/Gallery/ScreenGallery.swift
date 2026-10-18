import AppKit
import SwiftUI
import DropForgeCore
import DropForgeEngines

/// Renders real DropForge views offscreen to PNG (no screen recording involved). Used for visual review
/// (`--render-screens`) and by UI tests.
@MainActor
public enum ScreenGallery {
    public static func snapshot(of view: NSView, appearance: NSAppearance.Name = .aqua, settle: TimeInterval = 0.05) async -> Data? {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isOpaque = false
        window.backgroundColor = .clear
        let container = NSView(frame: view.frame)
        container.wantsLayer = true
        container.addSubview(view)
        window.contentView = container
        view.frame.origin = .zero
        container.layoutSubtreeIfNeeded()
        // Yield (rather than block) so async preview loading on the main actor can finish.
        try? await Task.sleep(for: .seconds(settle))
        container.layoutSubtreeIfNeeded()
        container.display()
        let bounds = container.bounds
        guard let rep = container.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            container.cacheDisplay(in: bounds, to: rep)
        }
        return rep.representation(using: .png, properties: [:])
    }

    public static func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name = .aqua, settle: TimeInterval = 0.6) async -> Data? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        return await snapshot(of: host, appearance: appearance, settle: settle)
    }

    static func wheel(_ selection: Selection?, category: OperationCategory, highlight: Int?, mode: WheelModel.Mode = .drag,
                      availability: EngineAvailability, scale: CGFloat = 1) -> WheelView {
        let model = WheelModel(mode: mode, category: category, resolver: CapabilityResolver(availability: availability))
        model.show(selection: selection)
        model.hover(highlight)
        let view = WheelView(model: model)
        view.scale = scale
        view.frame = NSRect(origin: .zero, size: WheelView.preferredSize(for: model.layout, scale: scale))
        return view
    }

    /// Writes the gallery into `directory` using fixtures generated in `fixtures`.
    public static func render(to directory: URL, fixtures: URL) async throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = FixtureFactory(directory: fixtures)
        let png = try await f.image("Holiday photo with a rather long descriptive file name 2026.png", format: .png, alpha: true)
        let jpg = try await f.image("photo.jpg", format: .jpeg, withMetadata: true)
        let pdf = try f.pdf("Quarterly report.pdf", pages: 4)
        let md = try f.text("notes.md", FixtureFactory.sampleMarkdown)
        let unknown = try f.text("data.bin", "x")
        var media: URL?
        if EngineLocator().ffmpeg != nil { media = try await f.video("clip.mp4", seconds: 2) }
        let all = EngineAvailability.everything
        let local = EngineLocator().availability()
        var written: [String] = []
        func save(_ name: String, _ data: Data?) throws {
            guard let data else { return }
            try data.write(to: directory.appendingPathComponent(name))
            written.append(name)
        }
        // Wheels (S02–S04)
        try save("S02-convert-single-light.png", await snapshot(of: wheel(Selection(urls: [png]), category: .convert, highlight: 1, availability: all)))
        try save("S02-convert-single-dark.png", await snapshot(of: wheel(Selection(urls: [png]), category: .convert, highlight: 1, availability: all), appearance: .darkAqua))
        try save("S02-convert-pdf-two-rings.png", await snapshot(of: wheel(Selection(urls: [pdf]), category: .convert, highlight: 8, availability: all)))
        try save("S02-convert-batch-mixed.png", await snapshot(of: wheel(Selection(urls: [png, jpg, md]), category: .convert, highlight: 0, availability: all)))
        try save("S02-convert-empty.png", await snapshot(of: wheel(Selection(urls: [unknown]), category: .tools, highlight: nil, availability: all)))
        try save("S02-reading.png", await snapshot(of: wheel(nil, category: .convert, highlight: nil, availability: all)))
        try save("S02-high-contrast.png", await snapshot(of: wheel(Selection(urls: [jpg]), category: .convert, highlight: 3, availability: all),
                                             appearance: .accessibilityHighContrastAqua))
        try save("S02-large.png", await snapshot(of: wheel(Selection(urls: [jpg]), category: .convert, highlight: 2, availability: all, scale: Tokens.Wheel.largeScale)))
        try save("S03-tools-image.png", await snapshot(of: wheel(Selection(urls: [jpg]), category: .tools, highlight: 0, mode: .keyboard, availability: all)))
        try save("S03-tools-pdf-dark.png", await snapshot(of: wheel(Selection(urls: [pdf]), category: .tools, highlight: 2, availability: all), appearance: .darkAqua))
        try save("S04-actions.png", await snapshot(of: wheel(Selection(urls: [png, pdf]), category: .actions, highlight: 1, availability: local)))

        // Picker (S05) — with an unavailable section (Pages export without Pages).
        let pages = try f.text("Letter.pages", "")
        let pickerModel = PickerModel(selection: Selection(urls: [pages]), category: .convert, resolver: CapabilityResolver(availability: .nativeOnly))
        try save("S05-picker-unavailable.png", await snapshot(PickerView(model: pickerModel), size: Tokens.Metrics.pickerSize))
        let pickerModel2 = PickerModel(selection: Selection(urls: [jpg]), category: .tools, resolver: CapabilityResolver(availability: all))
        try save("S05-picker-tools.png", await snapshot(PickerView(model: pickerModel2), size: Tokens.Metrics.pickerSize, appearance: .darkAqua))

        // Progress (S06) — every row state.
        let center = JobCenter()
        let op = Catalog.conversionDescriptor(.format(.jpeg), source: .png, combined: false)
        let units = (0..<5).map { PlannedUnit(id: $0, title: ["IMG_0001.png", "IMG_0002.png", "Scan.png", "photo.jpg", "IMG_0005.png"][$0],
                                             inputs: [], skipReason: $0 == 3 ? "Already JPG." : nil) }
        let record = JobRecord(plan: JobPlan(operation: op, parameters: .none, units: units))
        record.apply(.unitFinished(0, .succeeded([fixtures.appendingPathComponent("IMG_0001.jpg")], note: nil)))
        record.apply(.unitStarted(1)); record.apply(.unitProgress(1, 0.42))
        record.apply(.unitFinished(2, .failed("“Scan.png” could not be read as an image.")))
        record.apply(.unitFinished(4, .cancelled))
        center.adopt(record)
        try save("S06-progress.png", await snapshot(ProgressListView(center: center), size: CGSize(width: Tokens.Metrics.progressWidth, height: 430)))
        try save("S06-progress-empty.png", await snapshot(ProgressListView(center: JobCenter()), size: CGSize(width: Tokens.Metrics.progressWidth, height: 200)))

        // Editors (S07–S13)
        func ctx(_ urls: [URL], _ d: OperationDescriptor) -> EditorContext {
            EditorContext(selection: Selection(urls: urls), descriptor: d, apply: { _ in nil }, cancel: {})
        }
        let size = Tokens.Metrics.editorSize
        try save("S07-crop.png", await snapshot(CropEditor(context: ctx([jpg], Catalog.tool(.crop))), size: size, settle: 1.2))
        try save("S08-adjust.png", await snapshot(AdjustEditor(context: ctx([jpg], Catalog.tool(.adjust))), size: size, settle: 1.2))
        try save("S08-annotate.png", await snapshot(AnnotateEditor(context: ctx([jpg], Catalog.tool(.annotate))), size: size, settle: 1.2))
        try save("S08-frame.png", await snapshot(FrameEditor(context: ctx([png], Catalog.tool(.frame))), size: size, appearance: .darkAqua, settle: 1.5))
        try save("S08-redact.png", await snapshot(RedactEditor(context: ctx([jpg], Catalog.tool(.redact))), size: size, settle: 1.2))
        try save("S09-compress.png", await snapshot(CompressEditor(context: ctx([jpg, png], Catalog.tool(.compress))), size: size))
        try save("S10-metadata.png", await snapshot(MetadataEditor(context: ctx([jpg], Catalog.tool(.metadata))), size: size, settle: 1.2))
        if let media {
            try save("S11-trim.png", await snapshot(MediaToolEditor(context: ctx([media], Catalog.tool(.trim)), tool: .trim), size: size, settle: 1.5))
        }
        try save("S12-organize.png", await snapshot(PDFOrganizeEditor(context: ctx([pdf], Catalog.tool(.organize))), size: size, settle: 1.5))
        try save("S12-redact-pdf.png", await snapshot(PDFRedactEditor(context: ctx([pdf], Catalog.tool(.redact))), size: size, settle: 1.5))
        try save("S13-collage.png", await snapshot(CollageEditor(context: ctx([png, jpg, png], Catalog.tool(.collage))), size: size, settle: 1.5))
        try save("S13-rename.png", await snapshot(RenameEditor(context: ctx([png, jpg, pdf], Catalog.tool(.rename))), size: size))

        // Shelf, settings, welcome (S14, S15)
        let shelf = ShelfModel()
        shelf.add([png, pdf, md])
        try save("S14-shelf.png", await snapshot(ShelfView(model: shelf), size: Tokens.Metrics.shelfSize))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "DropForgeGallery-\(UUID().uuidString)")!)
        try save("S15-settings.png", await snapshot(SettingsView(settings: settings, locator: EngineLocator()), size: CGSize(width: 600, height: 520)))
        try save("S01-welcome.png", await snapshot(WelcomeView(gestures: .standard, onClose: {}), size: CGSize(width: 500, height: 420)))
        return written
    }
}

extension JobCenter {
    /// Gallery/test hook: shows a prepared record.
    func adopt(_ record: JobRecord) { appendForPreview(record) }
}
