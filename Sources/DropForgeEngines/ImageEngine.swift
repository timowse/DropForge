import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import DropForgeCore

public enum ImageError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case encodeFailed(String)
    case targetUnreachable(Int64)
    case missingEncoder(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "“\(name)” could not be read as an image."
        case .encodeFailed(let format): "macOS could not write this image as \(format)."
        case .targetUnreachable(let bytes):
            "Could not get below \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) without destroying the image."
        case .missingEncoder(let name): "The \(name) encoder is missing."
        }
    }
}

/// A decoded image with the metadata that should travel with it.
public struct LoadedImage: @unchecked Sendable {
    public let image: CGImage
    /// ImageIO properties of the source frame (orientation already applied to `image`).
    public let properties: [String: Any]
    public let hasAlpha: Bool
    public let frameCount: Int

    public var width: Int { image.width }
    public var height: Int { image.height }
}

public struct ImageEngine: Sendable {
    public let runner: ProcessRunning
    public let locator: EngineLocator

    public init(runner: ProcessRunning = SystemProcessRunner(), locator: EngineLocator = EngineLocator()) {
        self.runner = runner
        self.locator = locator
    }

    // MARK: Decoding

    static func typeIdentifier(for format: FileFormat) -> String? {
        switch format {
        case .jpeg: UTType.jpeg.identifier
        case .png: UTType.png.identifier
        case .heic: UTType.heic.identifier
        case .avif: "public.avif"
        case .tiff: UTType.tiff.identifier
        case .gif: UTType.gif.identifier
        case .bmp: UTType.bmp.identifier
        default: nil
        }
    }

    /// Decodes with EXIF orientation applied. SVG goes through AppKit's vector renderer.
    public func load(_ url: URL, maxPixelSize: Int? = nil) throws -> LoadedImage {
        if FileFormat.detect(url) == .svg { return try loadSVG(url, maxPixelSize: maxPixelSize) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageError.unreadable(url.lastPathComponent)
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let longest = max(w, h, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? longest, longest),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError.unreadable(url.lastPathComponent)
        }
        let alpha = (props[kCGImagePropertyHasAlpha as String] as? Bool) ?? Self.hasAlpha(image)
        return LoadedImage(image: image, properties: props, hasAlpha: alpha, frameCount: CGImageSourceGetCount(source))
    }

    func loadSVG(_ url: URL, maxPixelSize: Int?) throws -> LoadedImage {
        guard let nsImage = NSImage(contentsOf: url), nsImage.size.width > 0, nsImage.size.height > 0 else {
            throw ImageError.unreadable(url.lastPathComponent)
        }
        // Vector art: render at 2× its declared size, at least 1024 px on the long edge, at most 8192.
        let declared = max(nsImage.size.width, nsImage.size.height)
        var scale = max(2, 1024 / declared)
        scale = min(scale, 8192 / declared)
        if let maxPixelSize { scale = min(scale, Double(maxPixelSize) / declared) }
        let w = max(1, Int(nsImage.size.width * scale)), h = max(1, Int(nsImage.size.height * scale))
        guard let ctx = Self.makeContext(width: w, height: h) else { throw ImageError.unreadable(url.lastPathComponent) }
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        nsImage.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw ImageError.unreadable(url.lastPathComponent) }
        return LoadedImage(image: image, properties: [:], hasAlpha: true, frameCount: 1)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func makeContext(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Composites onto a background (for formats without transparency).
    public static func flatten(_ image: CGImage, background: RGBAColor = .white) -> CGImage {
        guard let ctx = makeContext(width: image.width, height: image.height, opaque: true) else { return image }
        ctx.setFillColor(CGColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    // MARK: Encoding

    /// Properties worth carrying to a re-encoded image: EXIF, GPS, IPTC, TIFF and colour info, orientation reset.
    static func carriedProperties(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let v = props[key as String] { out[key as String] = v }
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        out[kCGImagePropertyOrientation as String] = 1
        return out
    }

    /// Encodes to `data` (used for size searches).
    public func encode(_ image: CGImage, format: FileFormat, quality: Double?, properties: [String: Any] = [:]) throws -> Data {
        guard let type = Self.typeIdentifier(for: format) else { throw ImageError.encodeFailed(format.label) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ImageError.encodeFailed(format.label)
        }
        var props = properties
        if let quality { props[kCGImageDestinationLossyCompressionQuality as String] = quality }
        let input = (format == .jpeg || format == .bmp) && Self.hasAlpha(image) ? Self.flatten(image) : image
        CGImageDestinationAddImage(dest, input, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.encodeFailed(format.label) }
        return data as Data
    }

    /// Writes one image in any supported output format, including WebP (via cwebp) and PDF.
    public func write(_ image: CGImage, to url: URL, format: FileFormat, quality: Double? = nil,
                      properties: [String: Any] = [:], workspace: JobWorkspace? = nil) async throws {
        switch format {
        case .webp:
            try await writeWebP(image, to: url, quality: quality ?? 0.85, workspace: workspace)
        case .pdf:
            try Self.writePDF([image], to: url, dpi: (properties[kCGImagePropertyDPIWidth as String] as? Double) ?? 72)
        default:
            let data = try encode(image, format: format, quality: quality ?? Self.defaultQuality(format), properties: properties)
            try data.write(to: url, options: .withoutOverwriting)
        }
    }

    static func defaultQuality(_ format: FileFormat) -> Double? {
        switch format {
        case .jpeg, .heic, .avif: 0.88
        default: nil
        }
    }

    func writeWebP(_ image: CGImage, to url: URL, quality: Double, workspace: JobWorkspace?) async throws {
        guard let cwebp = locator.cwebp else { throw ImageError.missingEncoder("WebP") }
        let tempDir = workspace?.url ?? FileManager.default.temporaryDirectory
        let png = tempDir.appendingPathComponent("webp-source-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try encode(image, format: .png, quality: nil).write(to: png)
        let q = String(Int((min(max(quality, 0), 1) * 100).rounded()))
        try await runner.runChecked(Command(executable: cwebp,
                                            arguments: ["-quiet", "-mt", "-q", q, "-alpha_q", "100", "-metadata", "icc", png.path, "-o", url.path]))
    }

    /// One page per image, page size from pixel size and DPI.
    public static func writePDF(_ images: [CGImage], to url: URL, dpi: Double = 72,
                                pageSize: ImagesToPDFOptions = ImagesToPDFOptions()) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ImageError.encodeFailed("PDF") }
        let scale = 72 / max(dpi, 1)
        for image in images {
            let imageSize = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            var page = CGRect(origin: .zero, size: imageSize)
            if let (pw, ph) = pageSize.pageSize.points {
                page = CGRect(x: 0, y: 0, width: pageSize.landscape ? ph : pw, height: pageSize.landscape ? pw : ph)
            } else if pageSize.margin > 0 {
                page = CGRect(x: 0, y: 0, width: imageSize.width + 2 * pageSize.margin, height: imageSize.height + 2 * pageSize.margin)
            }
            let box = page.insetBy(dx: pageSize.margin, dy: pageSize.margin)
            let fit = min(box.width / imageSize.width, box.height / imageSize.height, pageSize.pageSize == .fitImage ? 1 : .greatestFiniteMagnitude)
            let drawSize = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
            let drawRect = CGRect(x: box.midX - drawSize.width / 2, y: box.midY - drawSize.height / 2,
                                  width: drawSize.width, height: drawSize.height)
            var mediaBox = page
            ctx.beginPage(mediaBox: &mediaBox)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: drawRect)
            ctx.endPage()
        }
        ctx.closePDF()
        try (data as Data).write(to: url, options: .withoutOverwriting)
    }

    // MARK: Conversion

    /// Converts keeping EXIF/GPS/colour metadata. Lossless containers are copied frame-exact.
    public func convert(_ input: URL, to format: FileFormat, output: URL, workspace: JobWorkspace?) async throws {
        let sourceFormat = FileFormat.detect(input)
        if format != .webp, format != .pdf, sourceFormat != .svg, let type = Self.typeIdentifier(for: format),
           let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            // Animated GIF → GIF keeps all frames; otherwise first frame with its metadata.
            let frames = format == .gif ? CGImageSourceGetCount(source) : 1
            guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, frames, nil) else {
                throw ImageError.encodeFailed(format.label)
            }
            let alpha = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])?[kCGImagePropertyHasAlpha as String] as? Bool ?? false
            if (format == .jpeg || format == .bmp) && alpha {
                let loaded = try load(input)
                var props = Self.carriedProperties(loaded.properties)
                if let q = Self.defaultQuality(format) { props[kCGImageDestinationLossyCompressionQuality as String] = q }
                CGImageDestinationAddImage(dest, Self.flatten(loaded.image), props as CFDictionary)
            } else {
                for i in 0..<frames {
                    var props: [String: Any] = [:]
                    if let q = Self.defaultQuality(format) { props[kCGImageDestinationLossyCompressionQuality as String] = q }
                    CGImageDestinationAddImageFromSource(dest, source, i, props as CFDictionary)
                }
            }
            guard CGImageDestinationFinalize(dest) else {
                try? FileManager.default.removeItem(at: output)
                throw ImageError.encodeFailed(format.label)
            }
            return
        }
        let loaded = try load(input)
        try await write(loaded.image, to: output, format: format, properties: Self.carriedProperties(loaded.properties), workspace: workspace)
    }

    // MARK: Geometry tools

    public static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = makeContext(width: max(1, width), height: max(1, height)) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    public static func targetSize(for mode: ResizeOptions.Mode, width w: Int, height h: Int) -> (Int, Int) {
        switch mode {
        case .scale(let p):
            return (max(1, w * p / 100), max(1, h * p / 100))
        case .fit(let mw, let mh):
            let s = min(Double(mw) / Double(w), Double(mh) / Double(h))
            return (max(1, Int((Double(w) * s).rounded())), max(1, Int((Double(h) * s).rounded())))
        case .exact(let ew, let eh):
            return (ew, eh)
        }
    }

    public static func limited(_ image: CGImage, maxDimension: Int?) -> CGImage {
        guard let m = maxDimension, max(image.width, image.height) > m else { return image }
        let (w, h) = targetSize(for: .fit(width: m, height: m), width: image.width, height: image.height)
        return resized(image, width: w, height: h) ?? image
    }

    public static func cropped(_ image: CGImage, to rect: UnitRect) -> CGImage? {
        let r = rect.pixelRect(width: image.width, height: image.height)
        // CGImage cropping uses a top-left origin.
        return image.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
    }

    public static func rotated(_ image: CGImage, _ o: RotateOptions) -> CGImage? {
        let swap = o.quarterTurns % 2 == 1
        let w = swap ? image.height : image.width, h = swap ? image.width : image.height
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(o.quarterTurns) * .pi / 2)
        ctx.scaleBy(x: o.flipHorizontal ? -1 : 1, y: o.flipVertical ? -1 : 1)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    // MARK: Adjustments

    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    public static func adjusted(_ image: CGImage, _ o: AdjustOptions) -> CGImage? {
        var ci = CIImage(cgImage: image)
        let extent = ci.extent
        if o.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: o.exposure])
        }
        if o.highlights != 0 || o.shadows != 0 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - o.highlights * 0.9, "inputShadowAmount": o.shadows,
            ])
        }
        if o.contrast != 0 || o.saturation != 0 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + o.contrast * 0.5, kCIInputSaturationKey: 1 + o.saturation,
                kCIInputBrightnessKey: 0,
            ])
        }
        if o.warmth != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - o.warmth * 2500, y: 0),
            ])
        }
        if o.sharpness > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: o.sharpness * 1.5, kCIInputRadiusKey: 1.6])
        }
        return ciContext.createCGImage(ci.cropped(to: extent), from: extent, format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: Annotation, frame, redaction

    /// Converts a unit rect (top-left origin) into CG coordinates (bottom-left origin).
    static func cgRect(_ r: UnitRect, width: Int, height: Int) -> CGRect {
        CGRect(x: r.x * Double(width), y: (1 - r.y - r.height) * Double(height),
               width: r.width * Double(width), height: r.height * Double(height))
    }

    static func cgColor(_ c: RGBAColor) -> CGColor { CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha) }

    public static func annotated(_ image: CGImage, _ o: AnnotationOptions) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let short = Double(min(w, h))
        for a in o.annotations {
            let rect = cgRect(a.rect, width: w, height: h)
            let lw = max(1, a.lineWidth * short)
            ctx.setStrokeColor(cgColor(a.color))
            ctx.setFillColor(cgColor(a.color))
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            switch a.shape {
            case .rectangle: ctx.stroke(rect)
            case .ellipse: ctx.strokeEllipse(in: rect)
            case .highlight:
                ctx.saveGState()
                ctx.setFillColor(cgColor(RGBAColor(red: a.color.red, green: a.color.green, blue: a.color.blue, alpha: 0.35)))
                ctx.setBlendMode(.multiply)
                ctx.fill(rect)
                ctx.restoreGState()
            case .line, .arrow:
                var start = a.startAtBottom ? CGPoint(x: rect.minX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.maxY)
                var end = a.startAtBottom ? CGPoint(x: rect.maxX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.minY)
                if a.reversed { swap(&start, &end) }
                ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
                if a.shape == .arrow {
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let head = lw * 4.5
                    ctx.move(to: end)
                    ctx.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 7), y: end.y - head * sin(angle - .pi / 7)))
                    ctx.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 7), y: end.y - head * sin(angle + .pi / 7)))
                    ctx.closePath()
                    ctx.fillPath()
                }
            case .text:
                drawText(a.text, in: rect, color: a.color, context: ctx)
            }
        }
        return ctx.makeImage()
    }

    static func drawText(_ text: String, in rect: CGRect, color: RGBAColor, context ctx: CGContext) {
        guard !text.isEmpty else { return }
        let size = max(8, rect.height * 0.8)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    public static func framed(_ image: CGImage, _ o: FrameOptions) -> CGImage? {
        let short = Double(min(image.width, image.height))
        let pad = o.padding * short
        var cw = Double(image.width) + 2 * pad, ch = Double(image.height) + 2 * pad
        if let aspect = o.canvasAspect, aspect > 0 {
            if cw / ch < aspect { cw = ch * aspect } else { ch = cw / aspect }
        }
        guard let ctx = makeContext(width: Int(cw.rounded()), height: Int(ch.rounded())) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: cw, height: ch)
        switch o.background {
        case .solid(let c):
            ctx.setFillColor(cgColor(c)); ctx.fill(canvas)
        case .gradient(let a, let b):
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [cgColor(a), cgColor(b)] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: ch), end: CGPoint(x: cw, y: 0), options: [])
            }
        case .transparent:
            break
        }
        let imageRect = CGRect(x: (cw - Double(image.width)) / 2, y: (ch - Double(image.height)) / 2,
                               width: Double(image.width), height: Double(image.height))
        let radius = o.cornerRadius * short
        let path = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // The shadow is cast by the clipped image itself (via a transparency layer), so transparent
        // pixels stay transparent instead of revealing a solid shadow shape.
        ctx.saveGState()
        if o.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -short * 0.012), blur: short * 0.04,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: imageRect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    public static func redacted(_ image: CGImage, _ o: RedactOptions) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let source = CIImage(cgImage: image)
        for region in o.regions {
            let rect = cgRect(region, width: w, height: h).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !rect.isEmpty else { continue }
            switch o.style {
            case .solid:
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(rect)
            case .pixelate, .blur:
                let scale = max(8, min(rect.width, rect.height) / 8)
                let filtered: CIImage = o.style == .pixelate
                    ? source.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale,
                                                                                          kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY)])
                    : source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: scale * 1.5])
                if let piece = ciContext.createCGImage(filtered, from: rect) {
                    ctx.draw(piece, in: rect)
                }
            }
        }
        return ctx.makeImage()
    }

    // MARK: Collage

    public static func collage(_ images: [CGImage], _ o: CollageOptions) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let cols = max(1, min(o.columns, images.count))
        let rows = Int(ceil(Double(images.count) / Double(cols)))
        let spacing = Double(o.spacing)
        let cellW = (Double(o.width) - spacing * Double(cols + 1)) / Double(cols)
        guard cellW > 4 else { return nil }
        var rowHeights: [Double] = []
        for r in 0..<rows {
            if let aspect = o.cellAspect, aspect > 0 {
                rowHeights.append(cellW / aspect)
            } else {
                let rowImages = images[(r * cols)..<min(images.count, (r + 1) * cols)]
                let avgAspect = rowImages.map { Double($0.width) / Double(max($0.height, 1)) }.reduce(0, +) / Double(rowImages.count)
                rowHeights.append(cellW / max(avgAspect, 0.1))
            }
        }
        let totalH = rowHeights.reduce(0, +) + spacing * Double(rows + 1)
        guard let ctx = makeContext(width: o.width, height: Int(totalH.rounded())) else { return nil }
        ctx.setFillColor(cgColor(o.background))
        ctx.fill(CGRect(x: 0, y: 0, width: Double(o.width), height: totalH))
        ctx.interpolationQuality = .high
        var top = spacing
        for r in 0..<rows {
            let rh = rowHeights[r]
            for c in 0..<cols {
                let i = r * cols + c
                guard i < images.count else { break }
                let img = images[i]
                let cell = CGRect(x: spacing + Double(c) * (cellW + spacing), y: totalH - top - rh, width: cellW, height: rh)
                // Aspect fill inside the cell.
                let s = max(cell.width / Double(img.width), cell.height / Double(img.height))
                let dw = Double(img.width) * s, dh = Double(img.height) * s
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: cell, cornerWidth: Double(o.cornerRadius), cornerHeight: Double(o.cornerRadius), transform: nil))
                ctx.clip()
                ctx.draw(img, in: CGRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh))
                ctx.restoreGState()
            }
            top += rh + spacing
        }
        return ctx.makeImage()
    }

    // MARK: Compression

    /// Format used when compressing: lossy formats stay; opaque lossless images become JPEG; transparent PNG stays PNG.
    public static func compressedFormat(for source: FileFormat?, hasAlpha: Bool) -> FileFormat {
        switch source {
        case .jpeg, .heic, .avif, .webp: return source!
        case .png, .gif, .tiff, .bmp, .svg, nil: return hasAlpha ? .png : .jpeg
        default: return .jpeg
        }
    }

    public static func quality(for preset: CompressOptions.Preset) -> Double {
        switch preset {
        case .high: 0.82
        case .balanced: 0.68
        case .small: 0.5
        }
    }

    /// Compresses to `format`. For a byte target it binary-searches quality, then shrinks dimensions if needed.
    public func compress(_ loaded: LoadedImage, options: CompressOptions, inputBytes: Int64, format: FileFormat,
                         output: URL, workspace: JobWorkspace?) async throws {
        let base = Self.limited(loaded.image, maxDimension: options.maxDimension)
        let props = Self.carriedProperties(loaded.properties)
        let target = FFmpegCommands.targetBytes(for: options.mode, inputBytes: inputBytes)
        if format == .webp {
            let q: Double
            if case .preset(let p) = options.mode { q = Self.quality(for: p) } else { q = 0.6 }
            try await write(base, to: output, format: .webp, quality: q, workspace: workspace)
            return
        }
        guard let target else {
            let q: Double? = { if case .preset(let p) = options.mode { return Self.quality(for: p) } ; return 0.7 }()
            let lossless = format == .png
            var image = base
            // PNG has no quality knob: "Smallest" also halves the pixel count.
            if lossless, case .preset(.small) = options.mode {
                image = Self.resized(base, width: Int(Double(base.width) * 0.707), height: Int(Double(base.height) * 0.707)) ?? base
            }
            let data = try encode(image, format: format, quality: lossless ? nil : q, properties: props)
            try data.write(to: output, options: .withoutOverwriting)
            return
        }
        var image = base
        for _ in 0..<8 {
            if format == .png {
                let data = try encode(image, format: .png, quality: nil, properties: props)
                if Int64(data.count) <= target { try data.write(to: output, options: .withoutOverwriting); return }
            } else {
                var lo = 0.05, hi = 0.95
                var best: Data?
                for _ in 0..<7 {
                    let mid = (lo + hi) / 2
                    let data = try encode(image, format: format, quality: mid, properties: props)
                    if Int64(data.count) <= target { best = data; lo = mid } else { hi = mid }
                }
                if best == nil {
                    let data = try encode(image, format: format, quality: 0.05, properties: props)
                    if Int64(data.count) <= target { best = data }
                }
                if let best { try best.write(to: output, options: .withoutOverwriting); return }
            }
            guard image.width > 32, image.height > 32,
                  let smaller = Self.resized(image, width: Int(Double(image.width) * 0.8), height: Int(Double(image.height) * 0.8))
            else { break }
            image = smaller
        }
        throw ImageError.targetUnreachable(target)
    }

    // MARK: Metadata

    /// Flattened metadata for display: (group, key, value).
    public static func metadataRows(_ url: URL) -> [(String, String, String)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        var rows: [(String, String, String)] = []
        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            if let dict = value as? [String: Any] {
                let group = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) { rows.append((group, k, describe(v))) }
            } else {
                rows.append(("Image", key, describe(value)))
            }
        }
        return rows
    }

    static func describe(_ v: Any) -> String {
        if let a = v as? [Any] { return a.map(describe).joined(separator: ", ") }
        if let d = v as? Data { return "\(d.count) bytes" }
        return String(describing: v)
    }

    /// Writes a copy with edited or removed metadata, without re-compressing the pixels when ImageIO allows it.
    public func rewriteMetadata(_ input: URL, output: URL, edit: MetadataEdit, workspace: JobWorkspace?) async throws {
        let format = FileFormat.detect(input)
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw ImageError.unreadable(input.lastPathComponent) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        let metadata: CGMutableImageMetadata
        if edit.removeAll {
            metadata = CGImageMetadataCreateMutable()
        } else if let existing = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let copy = CGImageMetadataCreateMutableCopy(existing) {
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        func set(_ dict: CFString, _ key: CFString, _ value: String?) {
            guard let value else { return }
            CGImageMetadataSetValueMatchingImageProperty(metadata, dict, key, value as CFString)
        }
        set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, edit.title)
        set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, edit.author)
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, edit.comment)
        if let k = edit.keywords {
            let list = k.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } as CFArray
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, list)
        }
        if format != .webp && format != .svg, let dest = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            var options: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageDestinationOrientation: orientation,
            ]
            if edit.removeAll || edit.removeLocation { options[kCGImageMetadataShouldExcludeGPS] = true }
            if edit.removeAll { options[kCGImageMetadataShouldExcludeXMP] = true }
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) {
                if edit.removeAll, try Self.stillHasPrivateMetadata(output) {
                    try? FileManager.default.removeItem(at: output)
                } else {
                    return
                }
            } else {
                try? FileManager.default.removeItem(at: output)
            }
        }
        // Fallback: re-encode pixels with only the kept properties.
        let loaded = try load(input)
        var kept: [String: Any] = edit.removeAll ? [:] : Self.carriedProperties(loaded.properties)
        if edit.removeLocation { kept.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        if edit.removeAll {
            kept[kCGImagePropertyOrientation as String] = 1
        }
        let outFormat = format.flatMap { $0.isInputOnly ? nil : $0 } ?? .png
        try await write(loaded.image, to: output, format: outFormat, quality: 0.95, properties: kept, workspace: workspace)
    }

    /// True when EXIF/GPS/TIFF camera fields survived a lossless metadata strip.
    static func stillHasPrivateMetadata(_ url: URL) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        if props[kCGImagePropertyGPSDictionary as String] != nil { return true }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let privateExif = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifLensModel, kCGImagePropertyExifBodySerialNumber,
                           kCGImagePropertyExifUserComment].map { $0 as String }
        if privateExif.contains(where: { exif[$0] != nil }) { return true }
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let privateTiff = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFDateTime]
            .map { $0 as String }
        return privateTiff.contains(where: { tiff[$0] != nil })
    }
}
