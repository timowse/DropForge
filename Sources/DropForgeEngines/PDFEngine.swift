import AppKit
import PDFKit
import DropForgeCore

public enum PDFError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case locked(String)
    case writeFailed
    case noText(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let n): "“\(n)” could not be opened as a PDF."
        case .locked(let n): "“\(n)” is password protected. Unlock it in Preview first."
        case .writeFailed: "The PDF could not be written."
        case .noText(let n): "“\(n)” contains no selectable text (it may be a scan)."
        }
    }
}

public struct PDFEngine: Sendable {
    public init() {}

    public func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PDFError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw PDFError.locked(url.lastPathComponent) }
        return doc
    }

    // MARK: Rendering

    /// Renders a page to a bitmap at `dpi`, white background, rotation applied. Caps the long edge at 12 000 px.
    public static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let sizePt = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        var scale = dpi / 72
        let longest = max(sizePt.width, sizePt.height) * scale
        if longest > 12_000 { scale *= 12_000 / longest }
        let w = max(1, Int((sizePt.width * scale).rounded())), h = max(1, Int((sizePt.height * scale).rounded()))
        guard let ctx = ImageEngine.makeContext(width: w, height: h, opaque: true) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Exports every page. One page → single file; more → numbered files in `directory`.
    public func exportPages(_ url: URL, format: FileFormat, dpi: Double, images: ImageEngine, directory: URL,
                            workspace: JobWorkspace, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let doc = try open(url)
        let count = doc.pageCount
        guard count > 0 else { throw PDFError.unreadable(url.lastPathComponent) }
        let digits = max(3, String(count).count)
        var outputs: [URL] = []
        for i in 0..<count {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let image = Self.render(page, dpi: dpi) else { continue }
            let name = String(format: "%0\(digits)d", i + 1) + "." + format.preferredExtension
            let out = directory.appendingPathComponent(name)
            try await images.write(image, to: out, format: format, quality: 0.9,
                                   properties: [kCGImagePropertyDPIWidth as String: dpi, kCGImagePropertyDPIHeight as String: dpi],
                                   workspace: workspace)
            outputs.append(out)
            progress(Double(i + 1) / Double(count))
        }
        return outputs
    }

    // MARK: Text

    public func plainText(_ url: URL) throws -> String {
        let doc = try open(url)
        var pages: [String] = []
        for i in 0..<doc.pageCount { pages.append(doc.page(at: i)?.string ?? "") }
        let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PDFError.noText(url.lastPathComponent) }
        return text + "\n"
    }

    public func attributedText(_ url: URL) throws -> NSAttributedString {
        let doc = try open(url)
        let out = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let s = doc.page(at: i)?.attributedString else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\n\n")) }
            out.append(s)
        }
        guard !out.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFError.noText(url.lastPathComponent) }
        return out
    }

    // MARK: Organisation

    public func merge(_ urls: [URL], output: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let result = PDFDocument()
        for (n, url) in urls.enumerated() {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
            progress(Double(n + 1) / Double(urls.count))
        }
        try write(result, to: output)
    }

    /// Splits into page groups; returns (label, file) pairs.
    public func split(_ url: URL, options: PDFSplitOptions, directory: URL) throws -> [(String, URL)] {
        let doc = try open(url)
        let n = doc.pageCount
        let groups: [[Int]]
        switch options.mode {
        case .everyPage: groups = (0..<n).map { [$0] }
        case .everyN(let k):
            let k = max(1, k)
            groups = stride(from: 0, to: n, by: k).map { Array($0..<min(n, $0 + k)) }
        case .ranges(let text): groups = try InputParsing.pageRanges(text, pageCount: n)
        }
        var outputs: [(String, URL)] = []
        for (gi, group) in groups.enumerated() {
            let part = PDFDocument()
            for i in group { if let p = doc.page(at: i)?.copy() as? PDFPage { part.insert(p, at: part.pageCount) } }
            let label = group.count == 1 ? "page \(group[0] + 1)" : "pages \(group.first! + 1)-\(group.last! + 1)"
            let out = directory.appendingPathComponent("\(gi + 1).pdf")
            try write(part, to: out)
            outputs.append((label, out))
        }
        return outputs
    }

    public func organize(_ url: URL, _ o: PageOrganization, output: URL) throws {
        let doc = try open(url)
        let result = PDFDocument()
        for p in o.pages {
            guard p.sourceIndex >= 0, p.sourceIndex < doc.pageCount,
                  let page = doc.page(at: p.sourceIndex)?.copy() as? PDFPage else {
                throw ValidationError("Page \(p.sourceIndex + 1) does not exist.")
            }
            page.rotation = ((page.rotation + p.rotation * 90) % 360 + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        if let attrs = doc.documentAttributes { result.documentAttributes = attrs }
        try write(result, to: output)
    }

    func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any]? = nil) throws {
        let ok = options.map { doc.write(to: url, withOptions: $0) } ?? doc.write(to: url)
        guard ok else { throw PDFError.writeFailed }
    }

    // MARK: Compression

    /// Returns a note when text was rasterised.
    @discardableResult
    public func compress(_ url: URL, options: CompressOptions, inputBytes: Int64, output: URL,
                         workspace: JobWorkspace, progress: @escaping @Sendable (Double) -> Void) throws -> String? {
        let doc = try open(url)
        let target = FFmpegCommands.targetBytes(for: options.mode, inputBytes: inputBytes)
        // Step 1: re-encode embedded images (keeps text and vectors).
        let optimised = workspace.file("optimised.pdf")
        let writeOptions: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        try write(doc, to: optimised, options: writeOptions)
        progress(0.3)
        let optimisedSize = Self.size(of: optimised)
        let wantsRaster: Bool
        if let target { wantsRaster = optimisedSize > target }
        else if case .preset(.small) = options.mode { wantsRaster = true }
        else { wantsRaster = false }
        if !wantsRaster {
            // Never hand back a "compressed" file larger than the original.
            let chosen = optimisedSize < inputBytes || inputBytes == 0 ? optimised : url
            try FileManager.default.copyItem(at: chosen, to: output)
            progress(1)
            return chosen == url ? "This PDF was already compact; the copy is unchanged." : nil
        }
        // Step 2: rasterise pages at decreasing resolution until the target fits.
        let ladder: [(Double, Double)] = target == nil ? [(120, 0.6)] : [(150, 0.7), (120, 0.6), (96, 0.5), (72, 0.4), (60, 0.3)]
        let images = ImageEngine()
        for (step, (dpi, quality)) in ladder.enumerated() {
            try Task.checkCancellation()
            let candidate = workspace.file("raster-\(Int(dpi)).pdf")
            try rasterize(doc, dpi: dpi, quality: quality, images: images, output: candidate)
            progress(0.3 + 0.7 * Double(step + 1) / Double(ladder.count))
            if target == nil || Self.size(of: candidate) <= target! || step == ladder.count - 1 {
                let fits = target.map { Self.size(of: candidate) <= $0 } ?? true
                guard fits else { throw ImageError.targetUnreachable(target!) }
                try FileManager.default.copyItem(at: candidate, to: output)
                return "To reach this size the pages were saved as images, so text is no longer selectable."
            }
        }
        throw PDFError.writeFailed
    }

    func rasterize(_ doc: PDFDocument, dpi: Double, quality: Double, images: ImageEngine, output: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw PDFError.writeFailed }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let image = Self.render(page, dpi: dpi) else { continue }
            let jpeg = try images.encode(image, format: .jpeg, quality: quality)
            guard let provider = CGDataProvider(data: jpeg as CFData),
                  let decoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(decoded, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        try (data as Data).write(to: output)
    }

    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: Metadata

    public func metadataRows(_ url: URL) -> [(String, String, String)] {
        guard let doc = try? open(url) else { return [] }
        var rows: [(String, String, String)] = [("Document", "Pages", "\(doc.pageCount)")]
        for (k, v) in (doc.documentAttributes ?? [:]).sorted(by: { "\($0.key)" < "\($1.key)" }) {
            rows.append(("Document", "\(k)", "\(v)"))
        }
        return rows
    }

    public func rewriteMetadata(_ url: URL, edit: MetadataEdit, output: URL) throws {
        let doc = try open(url)
        var attrs: [AnyHashable: Any] = edit.removeAll ? [:] : (doc.documentAttributes ?? [:])
        if edit.removeAll {
            // PDFKit adds its own Producer/Creator unless they are set explicitly.
            attrs[PDFDocumentAttribute.creatorAttribute] = ""
            attrs[PDFDocumentAttribute.producerAttribute] = ""
        }
        if let t = edit.title { attrs[PDFDocumentAttribute.titleAttribute] = t }
        if let a = edit.author { attrs[PDFDocumentAttribute.authorAttribute] = a }
        if let c = edit.comment { attrs[PDFDocumentAttribute.subjectAttribute] = c }
        if let k = edit.keywords {
            attrs[PDFDocumentAttribute.keywordsAttribute] = k.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        doc.documentAttributes = attrs
        try write(doc, to: output)
    }

    // MARK: Redaction

    /// Burns redactions in: affected pages are replaced by flattened images, so hidden text cannot be recovered.
    public func redact(_ url: URL, regions: [Int: [UnitRect]], output: URL, dpi: Double = 200) throws {
        let doc = try open(url)
        let result = PDFDocument()
        let images = ImageEngine()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let marks = regions[i], !marks.isEmpty, let image = Self.render(page, dpi: dpi),
               let burned = ImageEngine.redacted(image, RedactOptions(regions: marks, style: .solid)) {
                let tmp = NSMutableData()
                guard let consumer = CGDataConsumer(data: tmp as CFMutableData),
                      let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw PDFError.writeFailed }
                let jpeg = try images.encode(burned, format: .jpeg, quality: 0.9)
                guard let provider = CGDataProvider(data: jpeg as CFData),
                      let decoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw PDFError.writeFailed }
                var box = CGRect(x: 0, y: 0, width: Double(burned.width) * 72 / dpi, height: Double(burned.height) * 72 / dpi)
                ctx.beginPage(mediaBox: &box); ctx.draw(decoded, in: box); ctx.endPage(); ctx.closePDF()
                guard let flat = PDFDocument(data: tmp as Data)?.page(at: 0) else { throw PDFError.writeFailed }
                result.insert(flat, at: result.pageCount)
            } else if let copy = page.copy() as? PDFPage {
                result.insert(copy, at: result.pageCount)
            }
        }
        try write(result, to: output)
    }
}
