import AppKit
import DropForgeCore

public enum DocumentError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let n): "“\(n)” could not be read as a document."
        case .unsupported(let f): "\(f) documents cannot be written on this Mac."
        case .empty(let n): "“\(n)” contains no text."
        }
    }
}

/// Converts text documents with AppKit's text system. HTML import/export runs on the main actor, as AppKit requires.
public struct DocumentEngine: Sendable {
    public let runner: ProcessRunning

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    // MARK: Reading

    public static func readPlainText(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// Loads any supported document as attributed text.
    public func load(_ url: URL, workspace: JobWorkspace) async throws -> NSAttributedString {
        guard let format = FileFormat.detect(url) else { throw DocumentError.unreadable(url.lastPathComponent) }
        switch format {
        case .txt:
            let text = try Self.readPlainText(url)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        case .md:
            let html = MarkdownHTML.document(fromMarkdown: try Self.readPlainText(url), title: OutputNaming.stem(of: url))
            return try await Self.fromHTML(Data(html.utf8), baseURL: url.deletingLastPathComponent())
        case .html:
            return try await Self.fromHTML(try Data(contentsOf: url), baseURL: url.deletingLastPathComponent())
        case .epub:
            return try await loadEPUB(url, workspace: workspace)
        case .rtf, .rtfd, .docx, .doc, .odt:
            let type: NSAttributedString.DocumentType = switch format {
            case .rtf: .rtf
            case .rtfd: .rtfd
            case .docx: .officeOpenXML
            case .doc: .docFormat
            default: .openDocument
            }
            do {
                return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            } catch {
                throw DocumentError.unreadable(url.lastPathComponent)
            }
        default:
            throw DocumentError.unreadable(url.lastPathComponent)
        }
    }

    @MainActor
    static func fromHTMLOnMain(_ data: Data, baseURL: URL?) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL { options[.baseURL] = baseURL }
        return try NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    static func fromHTML(_ data: Data, baseURL: URL?) async throws -> NSAttributedString {
        let box = try await MainActor.run { SendableBox(try fromHTMLOnMain(data, baseURL: baseURL)) }
        return box.value
    }

    func loadEPUB(_ url: URL, workspace: JobWorkspace) async throws -> NSAttributedString {
        let dir = try workspace.subdirectory("epub-source")
        try await runner.runChecked(Command(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", url.path, dir.path]))
        let chapters = try EPUBReader.spine(in: dir)
        let out = NSMutableAttributedString()
        for chapter in chapters {
            let part = try await Self.fromHTML(try Data(contentsOf: chapter), baseURL: chapter.deletingLastPathComponent())
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(part)
        }
        return out
    }

    // MARK: Writing

    public func write(_ text: NSAttributedString, to output: URL, format: FileFormat, title: String,
                      markdownSource: String? = nil) async throws {
        if text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && markdownSource == nil {
            throw DocumentError.empty(title)
        }
        let range = NSRange(location: 0, length: text.length)
        let data: Data
        switch format {
        case .txt:
            data = Data(text.string.utf8)
        case .md:
            data = Data((markdownSource ?? MarkdownWriter.render(Self.paragraphs(from: text))).utf8)
        case .html:
            if let markdownSource {
                data = Data(MarkdownHTML.document(fromMarkdown: markdownSource, title: title).utf8)
            } else {
                let box = SendableBox(text)
                data = try await MainActor.run {
                    try box.value.data(from: NSRange(location: 0, length: box.value.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                            .characterEncoding: String.Encoding.utf8.rawValue, .title: title])
                }
            }
        case .rtf:
            data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case .docx:
            data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML, .title: title])
        case .odt:
            data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument, .title: title])
        case .epub:
            let paragraphs = Self.paragraphs(from: text)
            data = EPUBWriter.make(title: title, chapters: RichXHTML.chapters(paragraphs, fallbackTitle: title))
        case .pdf:
            let box = SendableBox(text)
            data = await MainActor.run { Self.paginatedPDF(box.value) }
        default:
            throw DocumentError.unsupported(format.label)
        }
        try data.write(to: output, options: .withoutOverwriting)
    }

    /// Lays out attributed text on A4 pages with TextKit and writes a PDF.
    @MainActor
    public static func paginatedPDF(_ text: NSAttributedString, pageSize: CGSize = CGSize(width: 595.28, height: 841.89),
                                    margin: CGFloat = 56) -> Data {
        let storage = NSTextStorage(attributedString: text.length > 0 ? text : NSAttributedString(string: " "))
        // Text without colour attributes should print black, not follow the system appearance.
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, r, _ in
            if value == nil { storage.addAttribute(.foregroundColor, value: NSColor.black, range: r) }
        }
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textSize = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: textSize)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            _ = layout.glyphRange(for: c)
        } while layout.glyphRange(for: containers.last!).upperBound < layout.numberOfGlyphs && containers.count < 5000

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for container in containers {
            let glyphs = layout.glyphRange(for: container)
            if glyphs.length == 0 && container !== containers.first { continue }
            ctx.beginPDFPage(nil)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: Attributed text → neutral model

    /// Recovers headings, lists, emphasis, code and links from attributed text.
    public static func paragraphs(from text: NSAttributedString) -> [RichParagraph] {
        let ns = text.string as NSString
        // Body size = the size used by most characters.
        var sizeCounts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            sizeCounts[size.rounded(), default: 0] += range.length
        }
        let body = sizeCounts.max { $0.value < $1.value }?.key ?? 12
        var result: [RichParagraph] = []
        var numberCounters: [Int: Int] = [:]
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { sub, range, _, _ in
            guard let sub, !sub.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let attrs = text.attributes(at: range.location, effectiveRange: nil)
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            var runs: [RichRun] = []
            var maxSize: CGFloat = 0
            var allBold = true
            var allMono = true
            text.enumerateAttributes(in: range) { a, r, _ in
                let piece = ns.substring(with: r)
                let font = a[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let bold = traits.contains(.boldFontMask)
                let italic = traits.contains(.italicFontMask)
                let mono = font?.isFixedPitch ?? false
                let link: String? = (a[.link] as? URL)?.absoluteString ?? (a[.link] as? String)
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    allBold = allBold && bold
                    allMono = allMono && mono
                    maxSize = max(maxSize, font?.pointSize ?? body)
                }
                runs.append(RichRun(text: piece, bold: bold, italic: italic, code: mono, link: link))
            }
            var text = sub
            var paragraphStyle: RichParagraph.Style = .body
            if let list = style?.textLists.last {
                let level = max(0, (style?.textLists.count ?? 1) - 1)
                let isOrdered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha")
                    || list.markerFormat.rawValue.contains("roman")
                // AppKit puts the marker ("\t•\t") into the text; drop it.
                let stripped = Self.stripListMarker(text)
                if stripped != text, let first = runs.first {
                    let removed = text.count - stripped.count
                    runs[0] = RichRun(text: String(first.text.dropFirst(min(removed, first.text.count))), bold: first.bold,
                                      italic: first.italic, code: first.code, link: first.link)
                    text = stripped
                }
                if isOrdered {
                    let n = (numberCounters[level] ?? 0) + 1
                    numberCounters[level] = n
                    paragraphStyle = .numbered(level: level, number: n)
                } else {
                    paragraphStyle = .bullet(level: level)
                }
            } else {
                numberCounters = [:]
                let ratio = maxSize / max(body, 1)
                if ratio >= 1.6 { paragraphStyle = .heading(1) }
                else if ratio >= 1.3 { paragraphStyle = .heading(2) }
                else if ratio >= 1.1 && allBold { paragraphStyle = .heading(3) }
                else if allMono && sub.count > 0 { paragraphStyle = .code }
                else if (style?.headIndent ?? 0) > 20 && (style?.firstLineHeadIndent ?? 0) > 20 { paragraphStyle = .quote }
            }
            if case .heading = paragraphStyle {
                runs = [RichRun(text: text.trimmingCharacters(in: .whitespaces))]
            }
            result.append(RichParagraph(style: paragraphStyle, runs: runs))
        }
        return result
    }

    static func stripListMarker(_ s: String) -> String {
        let pattern = #"^\t?(?:[•◦▪︎\-–*]|\d+[.)]|[a-zA-Z][.)]|[ivxlcIVXLC]+[.)])\t"#
        guard let r = s.range(of: pattern, options: .regularExpression) else { return s }
        return String(s[r.upperBound...])
    }
}

/// Moves non-Sendable AppKit values across an actor hop that is known to be safe (the value is not shared).
struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
