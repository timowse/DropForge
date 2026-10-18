import AppKit
import SwiftUI
import DropForgeCore
import DropForgeEngines

/// What every editor receives. `apply` returns a validation message, or nil when the job started.
public struct EditorContext {
    public let selection: Selection
    public let descriptor: OperationDescriptor
    public let apply: (ToolParameters) -> String?
    public let cancel: () -> Void
    /// Combining editors report a new input order here before applying.
    public var reorderHandler: (([URL]) -> Void)?

    public init(selection: Selection, descriptor: OperationDescriptor, apply: @escaping (ToolParameters) -> String?,
                cancel: @escaping () -> Void, reorderHandler: (([URL]) -> Void)? = nil) {
        self.selection = selection
        self.descriptor = descriptor
        self.apply = apply
        self.cancel = cancel
        self.reorderHandler = reorderHandler
    }

    var first: DroppedItem { selection.items[0] }
    var subtitle: String {
        selection.count == 1 ? first.url.lastPathComponent : "\(selection.count) files — the same settings apply to each"
    }
}

// MARK: - Crop (S07)

struct CropEditor: View {
    let context: EditorContext
    @StateObject private var preview = PreviewLoader()
    @State private var rect = UnitRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    @State private var ratioIndex = 0
    @State private var dragStart: UnitRect?
    @State private var dragCorner: CropGeometry.Corner?
    @State private var dragMoves = false
    @State private var resizeOutput = false
    @State private var outW = 0
    @State private var outH = 0
    @State private var error: String?

    var ratio: Double? {
        guard let r = CropGeometry.presets[ratioIndex].1 else { return nil }
        if r < 0 { return preview.pixelSize.height > 0 ? Double(preview.pixelSize.width / preview.pixelSize.height) : nil }
        return r
    }

    var pixel: (x: Int, y: Int, width: Int, height: Int) {
        rect.pixelRect(width: Int(preview.pixelSize.width), height: Int(preview.pixelSize.height))
    }

    var body: some View {
        EditorChrome(title: context.first.kind == .video ? "Crop video" : "Crop image", subtitle: context.subtitle, primaryTitle: "Crop",
                     error: error, canApply: preview.image != nil, onCancel: context.cancel, onApply: apply) {
            FittedImage(image: preview.image, failed: preview.failed) { frame in
                cropOverlay(frame)
            }
            .frame(minHeight: 320)
            HStack(spacing: Tokens.Metrics.spacingS) {
                Text("Aspect").foregroundStyle(.secondary)
                ForEach(Array(CropGeometry.presets.enumerated()), id: \.offset) { i, p in
                    Button(p.0) {
                        ratioIndex = i
                        if let r = ratio { rect = CropGeometry.apply(ratio: r, to: rect, imageWidth: preview.pixelSize.width, imageHeight: preview.pixelSize.height) }
                    }
                    .buttonStyle(.bordered)
                    .tint(i == ratioIndex ? .dfAccent : nil)
                    .accessibilityAddTraits(i == ratioIndex ? .isSelected : [])
                }
            }
            HStack(spacing: Tokens.Metrics.spacingM) {
                Text("Area \(pixel.width) × \(pixel.height) px at \(pixel.x), \(pixel.y)").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Toggle("Resize result to", isOn: $resizeOutput)
                TextField("Width", value: $outW, format: .number).frame(width: 70).disabled(!resizeOutput)
                    .accessibilityLabel("Output width in pixels")
                Text("×")
                TextField("Height", value: $outH, format: .number).frame(width: 70).disabled(!resizeOutput)
                    .accessibilityLabel("Output height in pixels")
                Button("Reset") { rect = .full; ratioIndex = 0 }
            }
        }
        .onAppear { preview.load(context.first.url, kind: context.first.kind) }
        .onChange(of: rect) { _, _ in if !resizeOutput { outW = pixel.width; outH = pixel.height } }
        .onChange(of: preview.pixelSize) { _, _ in outW = pixel.width; outH = pixel.height }
    }

    func cropOverlay(_ frame: CGRect) -> some View {
        let r = rect.view(in: frame)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(frame)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle().stroke(Color.white, lineWidth: 2).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            // Rule of thirds.
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
            ForEach(Array([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY),
                           CGPoint(x: r.maxX, y: r.maxY)].enumerated()), id: \.offset) { _, p in
                Circle().fill(Color.white).frame(width: 12, height: 12).offset(x: p.x - 6, y: p.y - 6)
                    .shadow(radius: 1)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
            guard frame.width > 0 else { return }
            let start = (Double((v.startLocation.x - frame.minX) / frame.width), Double((v.startLocation.y - frame.minY) / frame.height))
            if dragStart == nil {
                dragStart = rect
                dragCorner = CropGeometry.corner(near: start, of: rect, tolerance: Double(16 / frame.width))
                dragMoves = dragCorner == nil && start.0 >= rect.x && start.0 <= rect.x + rect.width
                    && start.1 >= rect.y && start.1 <= rect.y + rect.height
            }
            guard let base = dragStart else { return }
            let dx = Double(v.translation.width / frame.width), dy = Double(v.translation.height / frame.height)
            if let c = dragCorner {
                rect = CropGeometry.resized(base, corner: c, dx: dx, dy: dy, ratio: ratio,
                                            imageWidth: preview.pixelSize.width, imageHeight: preview.pixelSize.height)
            } else if dragMoves {
                rect = CropGeometry.moved(base, dx: dx, dy: dy)
            } else {
                var r = UnitRect.from(v.startLocation, v.location, in: frame)
                if let ratio { r = CropGeometry.apply(ratio: ratio, to: r, imageWidth: preview.pixelSize.width, imageHeight: preview.pixelSize.height) }
                rect = r
            }
        }.onEnded { _ in dragStart = nil; dragCorner = nil })
        .accessibilityElement()
        .accessibilityLabel("Crop area")
        .accessibilityValue("\(pixel.width) by \(pixel.height) pixels")
        .accessibilityAdjustableAction { direction in
            // VoiceOver: increment grows, decrement shrinks the area around its centre.
            let d = direction == .increment ? 0.02 : -0.02
            rect = UnitRect(x: max(0, rect.x - d), y: max(0, rect.y - d), width: min(1, rect.width + 2 * d), height: min(1, rect.height + 2 * d))
        }
    }

    func apply() {
        let options = CropOptions(rect: rect, outputWidth: resizeOutput ? outW : nil, outputHeight: resizeOutput ? outH : nil)
        error = context.apply(.crop(options))
    }
}

// MARK: - Resize

struct ResizeEditor: View {
    let context: EditorContext
    @StateObject private var preview = PreviewLoader()
    @State private var mode = 0
    @State private var percent = 50
    @State private var width = 1920
    @State private var height = 1080
    @State private var error: String?

    var body: some View {
        EditorChrome(title: "Resize", subtitle: context.subtitle, primaryTitle: "Resize", error: error, canApply: true,
                     onCancel: context.cancel, onApply: apply) {
            Form {
                if preview.pixelSize != .zero {
                    LabeledContent("Original", value: "\(Int(preview.pixelSize.width)) × \(Int(preview.pixelSize.height)) px")
                }
                Picker("Method", selection: $mode) {
                    Text("Scale by percentage").tag(0)
                    Text("Fit inside a box").tag(1)
                    Text("Exact size (may stretch)").tag(2)
                }
                .pickerStyle(.radioGroup)
                if mode == 0 {
                    Stepper(value: $percent, in: 1...400, step: 5) { Text("Scale \(percent) %") }
                } else {
                    HStack {
                        TextField("Width", value: $width, format: .number).frame(width: 90).accessibilityLabel("Width in pixels")
                        Text("×")
                        TextField("Height", value: $height, format: .number).frame(width: 90).accessibilityLabel("Height in pixels")
                        Text("pixels").foregroundStyle(.secondary)
                    }
                }
                if mode != 2, preview.pixelSize != .zero {
                    let (w, h) = ImageEngine.targetSize(for: resizeMode, width: Int(preview.pixelSize.width), height: Int(preview.pixelSize.height))
                    LabeledContent("Result", value: "\(w) × \(h) px")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { preview.load(context.first.url, kind: .image, maxPixels: 64) }
    }

    var resizeMode: ResizeOptions.Mode {
        switch mode {
        case 0: .scale(percent: percent)
        case 1: .fit(width: width, height: height)
        default: .exact(width: width, height: height)
        }
    }

    func apply() { error = context.apply(.resize(ResizeOptions(mode: resizeMode))) }
}

// MARK: - Rotate

struct RotateEditor: View {
    let context: EditorContext
    @StateObject private var preview = PreviewLoader()
    @State private var options = RotateOptions(quarterTurns: 0)
    @State private var error: String?

    var body: some View {
        EditorChrome(title: "Rotate or flip", subtitle: context.subtitle, primaryTitle: "Save", error: error,
                     canApply: options != RotateOptions(quarterTurns: 0), onCancel: context.cancel, onApply: apply) {
            FittedImage(image: preview.image, failed: preview.failed) { _ in EmptyView() }
                .rotationEffect(.degrees(Double(options.quarterTurns) * 90))
                .scaleEffect(x: options.flipHorizontal ? -1 : 1, y: options.flipVertical ? -1 : 1)
                .animation(Tokens.Motion.reduced ? nil : .easeInOut(duration: 0.2), value: options)
                .frame(minHeight: 300)
            HStack {
                Button { options = RotateOptions(quarterTurns: options.quarterTurns + 3, flipHorizontal: options.flipHorizontal, flipVertical: options.flipVertical) } label: { Label("Rotate left", systemImage: "rotate.left") }
                Button { options = RotateOptions(quarterTurns: options.quarterTurns + 1, flipHorizontal: options.flipHorizontal, flipVertical: options.flipVertical) } label: { Label("Rotate right", systemImage: "rotate.right") }
                Toggle("Flip horizontally", isOn: Binding(get: { options.flipHorizontal }, set: { options.flipHorizontal = $0 }))
                Toggle("Flip vertically", isOn: Binding(get: { options.flipVertical }, set: { options.flipVertical = $0 }))
            }
        }
        .onAppear { preview.load(context.first.url, kind: .image) }
    }

    func apply() { error = context.apply(.rotate(options)) }
}

// MARK: - Adjust (S08)

struct AdjustEditor: View {
    let context: EditorContext
    @StateObject private var preview = PreviewLoader()
    @State private var options = AdjustOptions()
    @State private var rendered: CGImage?
    @State private var error: String?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        EditorChrome(title: "Adjust", subtitle: context.subtitle, primaryTitle: "Save copy", error: error,
                     canApply: !options.isIdentity, onCancel: context.cancel, onApply: { error = context.apply(.adjust(options)) }) {
            HStack(alignment: .top, spacing: Tokens.Metrics.spacingL) {
                FittedImage(image: rendered ?? preview.image, failed: preview.failed) { _ in EmptyView() }
                    .frame(minWidth: 380, minHeight: 320)
                VStack(alignment: .leading, spacing: Tokens.Metrics.spacingS) {
                    slider("Exposure", \.exposure, -2...2)
                    slider("Contrast", \.contrast, -1...1)
                    slider("Highlights", \.highlights, 0...1)
                    slider("Shadows", \.shadows, 0...1)
                    slider("Saturation", \.saturation, -1...1)
                    slider("Warmth", \.warmth, -1...1)
                    slider("Sharpness", \.sharpness, 0...1)
                    Button("Reset all") { options = AdjustOptions() }.disabled(options.isIdentity)
                }
                .frame(width: 240)
            }
        }
        .onAppear { preview.load(context.first.url, kind: .image, maxPixels: 1200) }
        .onChange(of: options) { _, _ in rerender() }
    }

    func slider(_ title: String, _ key: WritableKeyPath<AdjustOptions, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%+.2f", options[keyPath: key])).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { options[keyPath: key] }, set: { options[keyPath: key] = $0 }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.2f", options[keyPath: key]))
        }
    }

    func rerender() {
        guard let base = preview.image else { return }
        renderTask?.cancel()
        let opts = options
        let box = SendablePreview(image: base, size: .zero)
        renderTask = Task.detached(priority: .userInitiated) {
            let out = ImageEngine.adjusted(box.image, opts).map { SendablePreview(image: $0, size: .zero) }
            if Task.isCancelled { return }
            await MainActor.run { rendered = out?.image }
        }
    }
}

// MARK: - Annotate (S08)

struct AnnotateEditor: View {
    let context: EditorContext
    @StateObject private var preview = PreviewLoader()
    @State private var marks: [Annotation] = []
    @State private var shape: Annotation.Shape = .arrow
    @State private var color = RGBAColor.swatches[0]
    @State private var width = 0.006
    @State private var text = "Note"
    @State private var draft: Annotation?
    @State private var error: String?

    var body: some View {
        EditorChrome(title: "Annotate", subtitle: context.subtitle, primaryTitle: "Save copy", error: error,
                     canApply: !marks.isEmpty, onCancel: context.cancel, onApply: { error = context.apply(.annotate(AnnotationOptions(annotations: marks))) }) {
            HStack(spacing: Tokens.Metrics.spacingS) {
                Picker("Mark", selection: $shape) {
                    Label("Arrow", systemImage: "arrow.up.right").tag(Annotation.Shape.arrow)
                    Label("Line", systemImage: "line.diagonal").tag(Annotation.Shape.line)
                    Label("Box", systemImage: "rectangle").tag(Annotation.Shape.rectangle)
                    Label("Oval", systemImage: "circle").tag(Annotation.Shape.ellipse)
                    Label("Highlight", systemImage: "highlighter").tag(Annotation.Shape.highlight)
                    Label("Text", systemImage: "textformat").tag(Annotation.Shape.text)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                if shape == .text { TextField("Text", text: $text).frame(width: 140).accessibilityLabel("Text to place") }
            }
            HStack {
                SwatchPicker(color: $color)
                Spacer()
                Text("Width")
                Slider(value: $width, in: 0.002...0.03).frame(width: 140).accessibilityLabel("Line width")
                Button("Undo") { _ = marks.popLast() }.disabled(marks.isEmpty).keyboardShortcut("z", modifiers: .command)
                Button("Clear") { marks.removeAll() }.disabled(marks.isEmpty)
            }
            FittedImage(image: preview.image, failed: preview.failed) { frame in
                ZStack(alignment: .topLeading) {
                    ForEach(marks + (draft.map { [$0] } ?? []), id: \.id) { a in
                        AnnotationShapeView(annotation: a, frame: frame)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let r = UnitRect.from(v.startLocation, v.location, in: frame)
                    let upward = v.location.y < v.startLocation.y
                    let leftward = v.location.x < v.startLocation.x
                    draft = Annotation(id: draft?.id ?? UUID(), shape: shape, rect: shape == .text ? textRect(at: v.location, frame: frame) : r,
                                       color: color, lineWidth: width, text: text, startAtBottom: upward != leftward,
                                       reversed: leftward)
                }.onEnded { _ in
                    if let d = draft, d.shape == .text || (d.rect.width > 0.005 || d.rect.height > 0.005) { marks.append(d) }
                    draft = nil
                })
                .accessibilityLabel("Drawing area. Drag to add a \(shape.rawValue).")
            }
            .frame(minHeight: 320)
            Text("Drag on the image to add marks. Arrows point to where you release.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { preview.load(context.first.url, kind: .image) }
    }

    func textRect(at p: CGPoint, frame: CGRect) -> UnitRect {
        let h = 0.06
        let w = min(0.9, Double(text.count) * h * 0.55)
        let x = Double((p.x - frame.minX) / max(frame.width, 1)), y = Double((p.y - frame.minY) / max(frame.height, 1)) - h / 2
        return UnitRect(x: min(max(0, x), 1 - w), y: min(max(0, y), 1 - h), width: w, height: h)
    }
}

/// Live view of one annotation, mirroring `ImageEngine.annotated`.
struct AnnotationShapeView: View {
    let annotation: Annotation
    let frame: CGRect

    /// View coordinates are top-left based; `startAtBottom` means the line rises left → right.
    func endpoints(in r: CGRect) -> (CGPoint, CGPoint) {
        let a = annotation.startAtBottom ? CGPoint(x: r.minX, y: r.maxY) : CGPoint(x: r.minX, y: r.minY)
        let b = annotation.startAtBottom ? CGPoint(x: r.maxX, y: r.minY) : CGPoint(x: r.maxX, y: r.maxY)
        return annotation.reversed ? (b, a) : (a, b)
    }

    var body: some View {
        let r = annotation.rect.view(in: frame)
        let lw = max(1, annotation.lineWidth * Double(min(frame.width, frame.height)))
        let c = annotation.color.color
        switch annotation.shape {
        case .rectangle:
            Rectangle().stroke(c, lineWidth: lw).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        case .ellipse:
            Ellipse().stroke(c, lineWidth: lw).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        case .highlight:
            Rectangle().fill(c.opacity(0.35)).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        case .text:
            Text(annotation.text).font(.system(size: max(8, r.height * 0.8), weight: .semibold)).foregroundStyle(c)
                .fixedSize().offset(x: r.minX, y: r.minY)
        case .line, .arrow:
            let (start, end) = endpoints(in: r)
            Path { p in
                p.move(to: start); p.addLine(to: end)
                if annotation.shape == .arrow {
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let head = lw * 4.5
                    p.move(to: end)
                    p.addLine(to: CGPoint(x: end.x - head * cos(angle - CGFloat.pi / 7), y: end.y - head * sin(angle - CGFloat.pi / 7)))
                    p.move(to: end)
                    p.addLine(to: CGPoint(x: end.x - head * cos(angle + CGFloat.pi / 7), y: end.y - head * sin(angle + CGFloat.pi / 7)))
                }
            }
            .stroke(c, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Frame / background (S08)

struct FrameEditor: View {
    let context: EditorContext
    @StateObject private var preview = PreviewLoader()
    @State private var backgroundKind = 0
    @State private var colorA = RGBAColor(red: 0.93, green: 0.95, blue: 0.96)
    @State private var colorB = RGBAColor(red: 0.31, green: 0.36, blue: 0.84)
    @State private var padding = 0.08
    @State private var radius = 0.03
    @State private var shadow = true
    @State private var aspectIndex = 0
    @State private var rendered: CGImage?
    @State private var error: String?
    static let aspects: [(String, Double?)] = [("Fit", nil), ("Square", 1), ("4:5", 0.8), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]

    var options: FrameOptions {
        let bg: FrameOptions.Background = switch backgroundKind {
        case 1: .gradient(colorA, colorB)
        case 2: .transparent
        default: .solid(colorA)
        }
        return FrameOptions(background: bg, padding: padding, cornerRadius: radius, shadow: shadow, canvasAspect: Self.aspects[aspectIndex].1)
    }

    var body: some View {
        EditorChrome(title: "Background and frame", subtitle: context.subtitle, primaryTitle: "Save copy", error: error, canApply: true,
                     onCancel: context.cancel, onApply: { error = context.apply(.frame(options)) }) {
            HStack(alignment: .top, spacing: Tokens.Metrics.spacingL) {
                FittedImage(image: rendered ?? preview.image, failed: preview.failed) { _ in EmptyView() }
                    .frame(minWidth: 380, minHeight: 320)
                Form {
                    Picker("Background", selection: $backgroundKind) {
                        Text("Solid").tag(0); Text("Gradient").tag(1); Text("Transparent").tag(2)
                    }
                    if backgroundKind != 2 {
                        ColorPicker("Colour", selection: Binding(get: { colorA.color }, set: { colorA = RGBAColor($0) }))
                    }
                    if backgroundKind == 1 {
                        ColorPicker("Second colour", selection: Binding(get: { colorB.color }, set: { colorB = RGBAColor($0) }))
                    }
                    Slider(value: $padding, in: 0...0.4) { Text("Padding") }
                    Slider(value: $radius, in: 0...0.25) { Text("Corners") }
                    Toggle("Shadow", isOn: $shadow)
                    Picker("Canvas", selection: $aspectIndex) {
                        ForEach(Array(Self.aspects.enumerated()), id: \.offset) { i, a in Text(a.0).tag(i) }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 280)
            }
        }
        .onAppear { preview.load(context.first.url, kind: .image, maxPixels: 900) }
        .onChange(of: options) { _, _ in rerender() }
        .onChange(of: preview.image != nil) { _, _ in rerender() }
    }

    func rerender() {
        guard let base = preview.image else { return }
        let o = options
        let box = SendablePreview(image: base, size: .zero)
        Task.detached(priority: .userInitiated) {
            let out = ImageEngine.framed(box.image, o).map { SendablePreview(image: $0, size: .zero) }
            await MainActor.run { rendered = out?.image }
        }
    }
}

// MARK: - Redact (image)

struct RedactEditor: View {
    let context: EditorContext
    @StateObject private var preview = PreviewLoader()
    @State private var regions: [UnitRect] = []
    @State private var draft: UnitRect?
    @State private var style: RedactOptions.Style = .solid
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        EditorChrome(title: "Redact", subtitle: context.subtitle, primaryTitle: "Save redacted copy", error: error,
                     canApply: !regions.isEmpty, onCancel: context.cancel,
                     onApply: { error = context.apply(.redact(RedactOptions(regions: regions, style: style))) }) {
            HStack {
                Button { detect(faces: true) } label: { Label("Find faces", systemImage: "face.dashed") }
                Button { detect(faces: false) } label: { Label("Find text", systemImage: "text.viewfinder") }
                Picker("Style", selection: $style) {
                    Text("Black box").tag(RedactOptions.Style.solid)
                    Text("Pixelate").tag(RedactOptions.Style.pixelate)
                    Text("Blur").tag(RedactOptions.Style.blur)
                }
                .frame(width: 220)
                Spacer()
                Button("Undo") { _ = regions.popLast() }.disabled(regions.isEmpty)
                Button("Clear") { regions.removeAll() }.disabled(regions.isEmpty)
            }
            FittedImage(image: preview.image, failed: preview.failed) { frame in
                ZStack(alignment: .topLeading) {
                    ForEach(Array((regions + (draft.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, r in
                        let v = r.view(in: frame)
                        Rectangle().fill(Color.black.opacity(style == .solid ? 0.9 : 0.55))
                            .overlay(Rectangle().stroke(Color.dfAccent, lineWidth: 1.5))
                            .frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                    draft = UnitRect.from(v.startLocation, v.location, in: frame)
                }.onEnded { _ in
                    if let d = draft { regions.append(d) }
                    draft = nil
                })
                .accessibilityLabel("Image. Drag to cover an area.")
            }
            .frame(minHeight: 320)
            Text(status ?? "Detection runs on this Mac. Review every box before saving; automatic detection can miss things.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { preview.load(context.first.url, kind: .image) }
    }

    func detect(faces: Bool) {
        guard let image = preview.image else { return }
        status = "Looking…"
        let box = SendablePreview(image: image, size: .zero)
        Task.detached(priority: .userInitiated) {
            let found = (try? (faces ? VisionEngine().faces(in: box.image) : VisionEngine().textRegions(in: box.image))) ?? []
            await MainActor.run {
                regions += found
                status = found.isEmpty ? "Nothing found. Draw boxes by hand." : "Added \(found.count) area\(found.count == 1 ? "" : "s"). Check them before saving."
            }
        }
    }
}
