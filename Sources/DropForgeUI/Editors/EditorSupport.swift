import AppKit
import AVFoundation
import SwiftUI
import DropForgeCore
import DropForgeEngines

/// Hosts one editor in a normal window. Closing the window counts as Cancel.
@MainActor
public final class EditorWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?
    private var finished = false

    public init<Content: View>(title: String, size: CGSize = Tokens.Metrics.editorSize, @ViewBuilder content: () -> Content) {
        window = NSWindow(contentViewController: NSHostingController(rootView: content().frame(minWidth: size.width * 0.8,
                                                                                               minHeight: size.height * 0.7)))
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init()
        window.delegate = self
    }

    public func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes without triggering the cancel callback.
    public func finish() {
        finished = true
        window.close()
    }

    public func windowWillClose(_ notification: Notification) {
        if !finished { onClose?() }
        finished = true
    }
}

/// Title row, content, error line and Cancel / primary buttons. Return applies, Escape cancels.
struct EditorChrome<Content: View>: View {
    let title: String
    let subtitle: String
    let primaryTitle: String
    let error: String?
    let canApply: Bool
    let onCancel: () -> Void
    let onApply: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrics.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            content
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.dfDanger)
                    .font(.callout)
                    .accessibilityLabel("Problem: \(error)")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
                    .tint(.dfAccent)
            }
        }
        .padding(Tokens.Metrics.spacingL)
    }
}

/// Loads a downscaled preview off the main thread.
@MainActor
final class PreviewLoader: ObservableObject {
    @Published var image: CGImage?
    @Published var pixelSize: CGSize = .zero
    @Published var failed = false

    func load(_ url: URL, kind: FileKind, maxPixels: Int = Tokens.Metrics.previewMaxPixels) {
        Task.detached(priority: .userInitiated) {
            var result: (CGImage, CGSize)?
            switch kind {
            case .image:
                let engine = ImageEngine()
                if let full = try? engine.load(url, maxPixelSize: maxPixels) {
                    let props = (CGImageSourceCreateWithURL(url as CFURL, nil)).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
                    var w = props?[kCGImagePropertyPixelWidth as String] as? Int ?? full.width
                    var h = props?[kCGImagePropertyPixelHeight as String] as? Int ?? full.height
                    if let o = props?[kCGImagePropertyOrientation as String] as? Int, o >= 5 { swap(&w, &h) }
                    if FileFormat.detect(url) == .svg { w = full.width; h = full.height }
                    result = (full.image, CGSize(width: w, height: h))
                }
            case .video:
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
                if let (img, _) = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                    let track = try? await asset.loadTracks(withMediaType: .video).first
                    var size = CGSize(width: img.width, height: img.height)
                    if let track, let natural = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
                        let r = CGRect(origin: .zero, size: natural).applying(t)
                        size = CGSize(width: abs(r.width), height: abs(r.height))
                    }
                    result = (img, size)
                }
            case .pdf:
                if let doc = PDFDocumentLoader.open(url), let page = doc.page(at: 0), let img = PDFEngine.render(page, dpi: 110) {
                    result = (img, CGSize(width: img.width, height: img.height))
                }
            default:
                break
            }
            let box = result.map { SendablePreview(image: $0.0, size: $0.1) }
            await MainActor.run {
                if let box { self.image = box.image; self.pixelSize = box.size } else { self.failed = true }
            }
        }
    }
}

struct SendablePreview: @unchecked Sendable {
    let image: CGImage
    let size: CGSize
}

import PDFKit
enum PDFDocumentLoader {
    static func open(_ url: URL) -> PDFDocument? { PDFDocument(url: url) }
}

/// Shows an image aspect-fit and exposes the displayed rect so overlays can map to unit coordinates.
struct FittedImage<Overlay: View>: View {
    let image: CGImage?
    let failed: Bool
    @ViewBuilder let overlay: (CGRect) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(container: geo.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Tokens.Metrics.cornerRadius).fill(Color(nsColor: .underPageBackgroundColor))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .accessibilityLabel("Preview")
                    overlay(rect)
                } else if failed {
                    Label("No preview available", systemImage: "eye.slash").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    func fittedRect(container: CGSize) -> CGRect {
        guard let image, image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let s = min(container.width / CGFloat(image.width), container.height / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

extension UnitRect {
    /// Unit rect → view rect inside `frame`.
    func view(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height, width: width * frame.width, height: height * frame.height)
    }

    /// Normalised rect spanned by two view points, clamped into `frame`.
    static func from(_ a: CGPoint, _ b: CGPoint, in frame: CGRect) -> UnitRect {
        guard frame.width > 0, frame.height > 0 else { return .full }
        func clampX(_ v: CGFloat) -> Double { Double(min(max((v - frame.minX) / frame.width, 0), 1)) }
        func clampY(_ v: CGFloat) -> Double { Double(min(max((v - frame.minY) / frame.height, 0), 1)) }
        let x0 = clampX(min(a.x, b.x)), x1 = clampX(max(a.x, b.x))
        let y0 = clampY(min(a.y, b.y)), y1 = clampY(max(a.y, b.y))
        return UnitRect(x: x0, y: y0, width: max(x1 - x0, 0.001), height: max(y1 - y0, 0.001))
    }
}

extension RGBAColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent),
                  alpha: Double(ns.alphaComponent))
    }

    static let swatches: [RGBAColor] = [
        RGBAColor(red: 0.90, green: 0.20, blue: 0.20), RGBAColor(red: 0.98, green: 0.80, blue: 0.10),
        RGBAColor(red: 0.18, green: 0.70, blue: 0.40), RGBAColor(red: 0.06, green: 0.49, blue: 0.53),
        RGBAColor(red: 0.31, green: 0.36, blue: 0.84), RGBAColor(red: 0.55, green: 0.30, blue: 0.75),
        .white, .black,
    ]
}

/// Row of colour swatches with VoiceOver names.
struct SwatchPicker: View {
    @Binding var color: RGBAColor
    static let names = ["Red", "Yellow", "Green", "Teal", "Indigo", "Purple", "White", "Black"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(RGBAColor.swatches.enumerated()), id: \.offset) { i, c in
                Button { color = c } label: {
                    Circle().fill(c.color)
                        .overlay(Circle().stroke(Color.primary.opacity(color == c ? 0.9 : 0.25), lineWidth: color == c ? 3 : 1))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.names[i])
                .accessibilityAddTraits(color == c ? .isSelected : [])
            }
            ColorPicker("Custom colour", selection: Binding(get: { color.color }, set: { color = RGBAColor($0) }))
                .labelsHidden()
        }
    }
}

/// Seconds text field bound to a Double, accepting "1:23.5".
struct TimeField: View {
    let label: String
    @Binding var seconds: Double
    @State private var text = ""

    var body: some View {
        TextField(label, text: $text)
            .frame(width: 90)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)
            .onAppear { text = InputParsing.formatTime(seconds) }
            .onChange(of: seconds) { _, v in
                if InputParsing.time(text) != v { text = InputParsing.formatTime(v) }
            }
            .onSubmit { if let v = InputParsing.time(text) { seconds = v } }
            .onChange(of: text) { _, t in if let v = InputParsing.time(t) { seconds = v } }
    }
}
