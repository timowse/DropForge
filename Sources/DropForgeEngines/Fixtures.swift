import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import DropForgeCore

/// Generates small, synthetic test files. Used by integration tests and `--smoke-test`; never touches user data.
public struct FixtureFactory: Sendable {
    public let directory: URL
    public let runner: ProcessRunning
    public let locator: EngineLocator

    public init(directory: URL, runner: ProcessRunning = SystemProcessRunner(), locator: EngineLocator = EngineLocator()) {
        self.directory = directory
        self.runner = runner
        self.locator = locator
    }

    /// A fresh, uniquely named temp directory.
    public static func makeTemporaryDirectory(prefix: String = "DropForgeFixtures") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: Images

    /// Gradient test card with a few shapes; alpha optional.
    public static func testImage(width: Int = 640, height: Int = 480, alpha: Bool = false) -> CGImage {
        let ctx = ImageEngine.makeContext(width: width, height: height, opaque: !alpha)!
        if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
        let colors = [CGColor(srgbRed: 0.06, green: 0.49, blue: 0.53, alpha: 1), CGColor(srgbRed: 0.31, green: 0.36, blue: 0.84, alpha: 1)]
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        if alpha {
            ctx.addEllipse(in: CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
            ctx.clip()
        }
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.resetClip()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: width / 10, y: height / 10, width: width / 5, height: height / 5))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width * 6 / 10, y: height * 5 / 10, width: width / 4, height: width / 4))
        return ctx.makeImage()!
    }

    /// Writes an image; JPEG/HEIC fixtures carry EXIF and GPS so metadata handling can be checked.
    @discardableResult
    public func image(_ name: String, format: FileFormat, width: Int = 640, height: Int = 480, alpha: Bool = false,
                      withMetadata: Bool = false) async throws -> URL {
        let out = url(name)
        let image = Self.testImage(width: width, height: height, alpha: alpha)
        var props: [String: Any] = [:]
        if withMetadata {
            props[kCGImagePropertyExifDictionary as String] = [kCGImagePropertyExifDateTimeOriginal as String: "2024:05:01 10:20:30",
                                                               kCGImagePropertyExifUserComment as String: "fixture comment"]
            props[kCGImagePropertyGPSDictionary as String] = [kCGImagePropertyGPSLatitude as String: 52.52, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                              kCGImagePropertyGPSLongitude as String: 13.40, kCGImagePropertyGPSLongitudeRef as String: "E"]
            props[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFMake as String: "FixtureCam", kCGImagePropertyTIFFModel as String: "One"]
        }
        try await ImageEngine(runner: runner, locator: locator).write(image, to: out, format: format, quality: 0.9, properties: props)
        return out
    }

    public func animatedGIF(_ name: String, frames: Int = 6) throws -> URL {
        let out = url(name)
        let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        for i in 0..<frames {
            let ctx = ImageEngine.makeContext(width: 160, height: 120, opaque: true)!
            ctx.setFillColor(CGColor(srgbRed: Double(i) / Double(frames), green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.1]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ImageError.encodeFailed("GIF") }
        return out
    }

    public func svg(_ name: String) throws -> URL {
        let out = url(name)
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">
          <rect width="200" height="120" fill="#0f7c86"/><circle cx="100" cy="60" r="40" fill="#ffd633"/>
        </svg>
        """
        try Data(svg.utf8).write(to: out)
        return out
    }

    public func qrCode(_ name: String, payload: String) throws -> URL {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let ci = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        // Quiet zone: put the code on a white canvas.
        let ctx = ImageEngine.makeContext(width: Int(ci.extent.width) + 96, height: Int(ci.extent.height) + 96, opaque: true)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        let cg = CIContext().createCGImage(ci, from: ci.extent)!
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 48, y: 48, width: ci.extent.width, height: ci.extent.height))
        let out = url(name)
        try ImageEngine().encode(ctx.makeImage()!, format: .png, quality: nil).write(to: out)
        return out
    }

    /// Black text on white, for OCR-assisted redaction.
    public func textImage(_ name: String, text: String = "Account 1234 5678") throws -> URL {
        let w = 900, h = 260
        let ctx = ImageEngine.makeContext(width: w, height: h, opaque: true)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: 40, y: 100)
        CTLineDraw(line, ctx)
        let out = url(name)
        try ImageEngine().encode(ctx.makeImage()!, format: .png, quality: nil).write(to: out)
        return out
    }

    // MARK: PDF

    /// Multi-page PDF with real text (title, headings, body) and one image per page.
    public func pdf(_ name: String, pages: Int = 3) throws -> URL {
        let out = url(name)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: "Fixture PDF",
                                                                 kCGPDFContextAuthor as String: "Fixture Author"] as CFDictionary)!
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            NSAttributedString(string: "Chapter \(p + 1)", attributes: [.font: NSFont.boldSystemFont(ofSize: 28)])
                .draw(at: CGPoint(x: 56, y: 760))
            let body = "This is page \(p + 1) of the DropForge fixture. It has selectable text for extraction tests."
            NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 12)])
                .draw(in: CGRect(x: 56, y: 600, width: 480, height: 140))
            NSGraphicsContext.restoreGraphicsState()
            ctx.draw(Self.testImage(width: 400, height: 300), in: CGRect(x: 56, y: 200, width: 400, height: 300))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try (data as Data).write(to: out)
        return out
    }

    // MARK: Documents

    public static let sampleMarkdown = """
    # DropForge fixture

    A paragraph with **bold**, *italic*, `code` and a [link](https://example.com).

    ## List

    - first item
    - second item

    1. one
    2. two

    > A quotation.

    | Name | Value |
    | --- | --- |
    | a | 1 |
    """

    @discardableResult
    public func text(_ name: String, _ contents: String) throws -> URL {
        let out = url(name)
        try Data(contents.utf8).write(to: out)
        return out
    }

    public func richDocument(_ name: String, type: NSAttributedString.DocumentType) throws -> URL {
        let s = NSMutableAttributedString(string: "Fixture heading\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        s.append(NSAttributedString(string: "Body text with ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        s.append(NSAttributedString(string: "bold words", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        s.append(NSAttributedString(string: " in a sentence.\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: type])
        let out = url(name)
        try data.write(to: out)
        return out
    }

    public func epub(_ name: String) throws -> URL {
        let paragraphs = [
            RichParagraph(style: .heading(1), runs: [RichRun(text: "First chapter")]),
            RichParagraph(style: .body, runs: [RichRun(text: "Hello from the "), RichRun(text: "EPUB", bold: true), RichRun(text: " fixture.")]),
            RichParagraph(style: .heading(1), runs: [RichRun(text: "Second chapter")]),
            RichParagraph(style: .body, runs: [RichRun(text: "More text.")]),
        ]
        let out = url(name)
        try EPUBWriter.make(title: "Fixture Book", author: "DropForge", chapters: RichXHTML.chapters(paragraphs, fallbackTitle: "Fixture")).write(to: out)
        return out
    }

    public static let sampleSRT = """
    1
    00:00:01,000 --> 00:00:02,500
    Hello <i>there</i>.

    2
    00:00:03,000 --> 00:00:04,000
    Second line
    with a break.

    """

    // MARK: Media (needs ffmpeg)

    func ffmpeg(_ args: [String]) async throws {
        guard let ffmpeg = locator.ffmpeg else { throw MediaError.missingFFmpeg }
        try await runner.runChecked(Command(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"] + args))
    }

    /// Test pattern with a tone. Codec chosen per container.
    @discardableResult
    public func video(_ name: String, seconds: Double = 2, size: String = "320x240", withAudio: Bool = true) async throws -> URL {
        let out = url(name)
        var args = ["-f", "lavfi", "-i", "testsrc=size=\(size):rate=25:duration=\(seconds)"]
        if withAudio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)"] }
        switch FileFormat.detect(out) {
        case .webm: args += ["-c:v", "libvpx-vp9", "-b:v", "300k", "-deadline", "realtime"] + (withAudio ? ["-c:a", "libopus"] : [])
        case .avi: args += ["-c:v", "mpeg4", "-q:v", "5"] + (withAudio ? ["-c:a", "libmp3lame"] : [])
        case .wmv: args += ["-c:v", "wmv2", "-b:v", "400k"] + (withAudio ? ["-c:a", "wmav2"] : [])
        default: args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"] + (withAudio ? ["-c:a", "aac"] : [])
        }
        args += ["-metadata", "title=Fixture video", "-metadata", "comment=fixture"]
        try await ffmpeg(args + ["-shortest", out.path])
        return out
    }

    @discardableResult
    public func audio(_ name: String, seconds: Double = 2) async throws -> URL {
        let out = url(name)
        var args = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=\(seconds)", "-ac", "2",
                    "-metadata", "title=Fixture tone", "-metadata", "artist=DropForge"]
        switch FileFormat.detect(out) {
        case .mp3: args += ["-c:a", "libmp3lame"]
        case .m4a: args += ["-c:a", "aac"]
        case .flac: args += ["-c:a", "flac"]
        case .ogg: args += ["-c:a", "vorbis", "-strict", "experimental"]
        case .opus: args += ["-c:a", "libopus"]
        case .aiff: args += ["-c:a", "pcm_s16be"]
        case .wma: args += ["-c:a", "wmav2"]
        default: args += ["-c:a", "pcm_s16le"]
        }
        try await ffmpeg(args + [out.path])
        return out
    }

    // MARK: Archives

    public func archive(_ name: String, format: FileFormat, containing files: [URL]) async throws -> URL {
        let out = url(name)
        try await ArchiveEngine(runner: runner).create(format, items: files, output: out)
        return out
    }
}
