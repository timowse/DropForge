import AppKit
import PDFKit
import DropForgeCore

/// Routes every conversion and tool to the right engine. Writes only inside the unit's workspace.
public struct DefaultPerformer: UnitPerformer {
    public let images: ImageEngine
    public let media: MediaEngine
    public let pdf: PDFEngine
    public let documents: DocumentEngine
    public let office: OfficeEngine
    public let archives: ArchiveEngine
    public let vision: VisionEngine
    public var pdfExportDPI: Double

    public init(runner: ProcessRunning = SystemProcessRunner(), locator: EngineLocator = EngineLocator(), pdfExportDPI: Double = 300) {
        images = ImageEngine(runner: runner, locator: locator)
        media = MediaEngine(runner: runner, locator: locator)
        pdf = PDFEngine()
        documents = DocumentEngine(runner: runner)
        office = OfficeEngine(runner: runner, locator: locator)
        archives = ArchiveEngine(runner: runner)
        vision = VisionEngine()
        self.pdfExportDPI = pdfExportDPI
    }

    public func perform(_ r: UnitRequest, context c: UnitContext) async throws -> [StagedOutput] {
        switch r.operation.kind {
        case .convert(.extract):
            let item = r.primary
            let (url, isFolder) = try await archives.extract(item.url, workspace: c.workspace)
            c.progress(1)
            if isFolder { return [StagedOutput(url: url, base: OutputNaming.stem(of: item.url), ext: "")] }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return [StagedOutput(url: url, base: isDir ? url.lastPathComponent : OutputNaming.stem(of: url),
                                 ext: isDir ? "" : url.pathExtension)]
        case .convert(.format(let format)):
            return try await convert(r, to: format, c)
        case .tool(let tool):
            return try await self.tool(tool, r, c)
        case .action:
            throw ValidationError("Actions are handled by the app.")
        }
    }

    // MARK: - Conversion

    func convert(_ r: UnitRequest, to format: FileFormat, _ c: UnitContext) async throws -> [StagedOutput] {
        let item = r.primary
        let input = item.url
        let source = item.isDirectory ? nil : item.format
        let ws = c.workspace
        let base = OutputNaming.baseName(for: input)
        let out = ws.file("output.\(format.preferredExtension)")
        func single(_ url: URL = out, note: String? = nil) -> [StagedOutput] {
            c.progress(1)
            return [StagedOutput(url: url, base: base, ext: format.preferredExtension, note: note)]
        }

        if format.kind == .archive {
            var items = r.inputs.map(\.url)
            if let source, source.kind == .archive, r.inputs.count == 1 {
                // Repack: extract first, then archive the contents under the original name.
                let (extracted, isFolder) = try await archives.extract(input, workspace: ws)
                items = isFolder ? try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil) : [extracted]
                c.progress(0.5)
            }
            try await archives.create(format, items: items, output: out)
            let name = r.inputs.count == 1 ? (source?.kind == .archive ? base : input.lastPathComponent) : "Archive"
            c.progress(1)
            return [StagedOutput(url: out, base: name, ext: format.preferredExtension)]
        }

        switch source?.kind {
        case .image:
            if format.kind == .video {
                try await media.convert(input, to: format, output: out, progress: c.progress)
            } else {
                try await images.convert(input, to: format, output: out, workspace: ws)
            }
            return single()

        case .video, .audio:
            try await media.convert(input, to: format, output: out, progress: c.progress)
            return single()

        case .pdf:
            return try await convertPDF(r, to: format, c, base: base, out: out)

        case .document:
            if r.engine == .pages {
                let produced = try await office.iWork(.pages, input: input, to: format, workspace: ws)
                return single(produced)
            }
            if r.engine == .libreOffice {
                let produced = try await office.libreOffice(input, to: format, workspace: ws)
                return single(produced)
            }
            let text = try await documents.load(input, workspace: ws)
            c.progress(0.5)
            let markdown = source == .md ? try DocumentEngine.readPlainText(input) : nil
            try await documents.write(text, to: out, format: format, title: base, markdownSource: markdown)
            return single()

        case .slides:
            let wantsImages = format == .jpeg || format == .png
            let target: FileFormat = wantsImages ? .pdf : format
            let produced = r.engine == .keynote
                ? try await office.iWork(.keynote, input: input, to: target, workspace: ws)
                : try await office.libreOffice(input, to: target, workspace: ws)
            guard wantsImages else { return single(produced) }
            c.progress(0.4)
            return try await pagesAsImages(produced, format: format, base: base, c)

        case .spreadsheet:
            if (source == .csv || source == .tsv) && (format == .csv || format == .tsv) {
                let text = try DocumentEngine.readPlainText(input)
                let converted = DelimitedText.convert(text, from: source == .csv ? DelimitedText.sniffDelimiter(text) : "\t",
                                                      to: format == .csv ? "," : "\t")
                try Data(converted.utf8).write(to: out)
                return single()
            }
            if r.engine == .numbers {
                if format == .tsv {
                    let csv = try await office.iWork(.numbers, input: input, to: .csv, workspace: ws)
                    let converted = DelimitedText.convert(try DocumentEngine.readPlainText(csv), from: ",", to: "\t")
                    try Data(converted.utf8).write(to: out)
                    return single()
                }
                return single(try await office.iWork(.numbers, input: input, to: format, workspace: ws))
            }
            return single(try await office.libreOffice(input, to: format, workspace: ws))

        case .subtitle:
            let cues = try Subtitles.parse(try DocumentEngine.readPlainText(input))
            let text: String = switch format {
            case .srt: Subtitles.srt(cues)
            case .vtt: Subtitles.vtt(cues)
            default: Subtitles.plainText(cues)
            }
            try Data(text.utf8).write(to: out)
            return single()

        default:
            throw ValidationError("DropForge cannot convert this item to \(format.label).")
        }
    }

    func convertPDF(_ r: UnitRequest, to format: FileFormat, _ c: UnitContext, base: String, out: URL) async throws -> [StagedOutput] {
        let input = r.primary.url
        switch format {
        case .jpeg, .png:
            return try await pagesAsImages(input, format: format, base: base, c)
        case .txt:
            try Data(try pdf.plainText(input).utf8).write(to: out)
        case .md:
            let text = try pdf.attributedText(input)
            try Data(MarkdownWriter.render(DocumentEngine.paragraphs(from: text)).utf8).write(to: out)
        case .docx, .html, .rtf, .epub, .odt:
            let text = try pdf.attributedText(input)
            c.progress(0.5)
            try await documents.write(text, to: out, format: format, title: base)
        case .pptx:
            let doc = try pdf.open(input)
            var slides: [Data] = []
            var aspect = 16.0 / 9
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: i), let image = PDFEngine.render(page, dpi: 150) else { continue }
                if i == 0 { aspect = Double(image.width) / Double(max(image.height, 1)) }
                slides.append(try images.encode(image, format: .png, quality: nil))
                c.progress(Double(i + 1) / Double(doc.pageCount) * 0.9)
            }
            guard !slides.isEmpty else { throw PDFError.unreadable(input.lastPathComponent) }
            try PPTXWriter.make(slides: slides, aspect: aspect).write(to: out)
        default:
            throw ValidationError("PDF cannot be converted to \(format.label).")
        }
        c.progress(1)
        return [StagedOutput(url: out, base: base, ext: format.preferredExtension)]
    }

    /// Renders every page; a single page becomes one image, several become a folder of numbered images.
    func pagesAsImages(_ pdfURL: URL, format: FileFormat, base: String, _ c: UnitContext) async throws -> [StagedOutput] {
        let dir = try c.workspace.subdirectory("pages-\(UUID().uuidString)")
        let pages = try await pdf.exportPages(pdfURL, format: format, dpi: pdfExportDPI, images: images, directory: dir,
                                              workspace: c.workspace, progress: c.progress)
        guard !pages.isEmpty else { throw PDFError.unreadable(pdfURL.lastPathComponent) }
        if pages.count == 1 { return [StagedOutput(url: pages[0], base: base, ext: format.preferredExtension)] }
        try nameChildren(in: dir, files: pages, base: base)
        return [StagedOutput(url: dir, base: "\(base) pages", ext: "")]
    }

    /// Renames numbered files in a staging folder to "<base> 001.ext".
    func nameChildren(in dir: URL, files: [URL], base: String) throws {
        for file in files {
            let target = dir.appendingPathComponent("\(OutputNaming.fit(stem: base, extension: file.pathExtension)) \(file.lastPathComponent)")
            try FileManager.default.moveItem(at: file, to: target)
        }
    }

    // MARK: - Tools

    /// Output format for edits of a media file (input-only containers become their closest writable sibling).
    static func editableMediaFormat(_ f: FileFormat?) -> FileFormat {
        switch f {
        case .avi, .wmv, .m4v, .none: .mp4
        case .wma, .aac: .m4a
        case .some(let f) where f.kind == .image: .mp4
        case .some(let f): f
        }
    }

    /// Output format for image edits.
    func editableImageFormat(_ f: FileFormat?) -> FileFormat {
        switch f {
        case .svg, .none: .png
        case .webp: images.locator.cwebp == nil ? .png : .webp
        case .some(let f): f.kind == .image ? f : .png
        }
    }

    func tool(_ tool: ToolKind, _ r: UnitRequest, _ c: UnitContext) async throws -> [StagedOutput] {
        let item = r.primary
        let input = item.url
        let ws = c.workspace
        let suffix = OutputNaming.suffix(for: tool)
        let base = OutputNaming.baseName(for: input, suffix: suffix)

        switch tool {
        case .compress:
            let options: CompressOptions = { if case .compress(let o) = r.parameters { return o } ; return CompressOptions() }()
            switch item.kind {
            case .image:
                let loaded = try images.load(input)
                let format = ImageEngine.compressedFormat(for: item.format, hasAlpha: loaded.hasAlpha)
                let out = ws.file("compressed.\(format.preferredExtension)")
                try await images.compress(loaded, options: options, inputBytes: item.byteSize, format: format, output: out, workspace: ws)
                let note = format != item.format ? "Saved as \(format.label) because \(item.format?.label ?? "this format") has no lossy compression." : nil
                return done(out, base, format.preferredExtension, c, note: note)
            case .video, .audio:
                let format = item.kind == .video ? FFmpegCommands.compressedVideoFormat(for: item.format ?? .mp4)
                                                 : FFmpegCommands.compressedAudioFormat(for: item.format ?? .m4a)
                let out = ws.file("compressed.\(format.preferredExtension)")
                try await media.compress(input, kind: item.kind, format: format, options: options, inputBytes: item.byteSize,
                                         output: out, progress: c.progress)
                return done(out, base, format.preferredExtension, c)
            case .pdf:
                let out = ws.file("compressed.pdf")
                let note = try pdf.compress(input, options: options, inputBytes: item.byteSize, output: out, workspace: ws, progress: c.progress)
                return done(out, base, "pdf", c, note: note)
            default:
                throw ValidationError("This kind of file cannot be compressed. Try “Archive as ZIP”.")
            }

        case .resize, .crop, .rotate, .adjust, .annotate, .frame, .redact:
            if item.kind == .video && tool == .crop {
                guard case .crop(let o) = r.parameters else { throw ValidationError("Choose a crop area.") }
                let format = Self.editableMediaFormat(item.format)
                let out = ws.file("cropped.\(format.preferredExtension)")
                try await media.crop(input, format: format, rect: o.rect, output: out, progress: c.progress)
                return done(out, base, format.preferredExtension, c)
            }
            if item.kind == .pdf && tool == .redact {
                guard case .redact(let o) = r.parameters else { throw ValidationError("Mark areas to redact.") }
                let out = ws.file("redacted.pdf")
                try pdf.redact(input, regions: o.pageRegions, output: out)
                return done(out, base, "pdf", c, note: "Redacted pages were flattened to images so the hidden text is gone.")
            }
            return try await imageEdit(tool, r, c, base: base)

        case .metadata, .stripMetadata:
            let edit: MetadataEdit
            if tool == .stripMetadata { edit = MetadataEdit(removeAll: true, removeLocation: true) }
            else if case .metadata(let e) = r.parameters { edit = e }
            else { throw ValidationError("Nothing was changed.") }
            switch item.kind {
            case .image:
                let format = editableImageFormat(item.format)
                let out = ws.file("meta.\(format.preferredExtension)")
                try await images.rewriteMetadata(input, output: out, edit: edit, workspace: ws)
                return done(out, base, format.preferredExtension, c)
            case .pdf:
                let out = ws.file("meta.pdf")
                try pdf.rewriteMetadata(input, edit: edit, output: out)
                return done(out, base, "pdf", c)
            case .video, .audio:
                // Stream copy needs a container that can hold the streams; keep the original one.
                let ext = input.pathExtension.lowercased()
                let out = ws.file("meta.\(ext)")
                let args = tool == .stripMetadata ? FFmpegCommands.stripMetadata(input: input, output: out)
                                                  : FFmpegCommands.editMetadata(input: input, output: out, edit: edit)
                try await media.run({ _ in args }, input: input, progress: c.progress)
                return done(out, base, ext, c)
            default:
                throw ValidationError("DropForge cannot edit metadata of this kind of file.")
            }

        case .trim, .speed, .mute, .normalize, .channels, .bleep:
            let format = Self.editableMediaFormat(item.format)
            let out = ws.file("edit.\(format.preferredExtension)")
            switch (tool, r.parameters) {
            case (.trim, .trim(let span)):
                try await media.trim(input, format: format, span: span, output: out, progress: c.progress)
            case (.speed, .speed(let f)):
                try await media.speed(input, format: format, factor: f, output: out, progress: c.progress)
            case (.mute, _):
                try await media.run({ _ in FFmpegCommands.mute(input: input, output: out) }, input: input, progress: c.progress)
            case (.normalize, let p):
                let o: NormalizeOptions = { if case .normalize(let o) = p { return o } ; return NormalizeOptions() }()
                try await media.run({ FFmpegCommands.normalize(input: input, output: out, format: format, options: o, info: $0) },
                                    input: input, requireAudio: true, progress: c.progress)
            case (.channels, .channels(let mode)):
                try await media.run({ FFmpegCommands.channels(input: input, output: out, format: format, mode: mode, info: $0) },
                                    input: input, requireAudio: true, progress: c.progress)
            case (.bleep, .bleep(let o)):
                try await media.run({ FFmpegCommands.bleep(input: input, output: out, format: format, options: o, info: $0) },
                                    input: input, requireAudio: true, progress: c.progress)
            default:
                throw ValidationError("Missing settings for this tool.")
            }
            let label = tool == .speed ? { if case .speed(let f) = r.parameters { return "\(OutputNaming.baseName(for: input)) \(String(format: "%g", f))x" } ; return base }() : base
            return done(out, label, format.preferredExtension, c)

        case .split:
            if item.kind == .pdf {
                guard case .pdfSplit(let o) = r.parameters else { throw ValidationError("Choose how to split.") }
                let dir = try ws.subdirectory("split")
                let parts = try pdf.split(input, options: o, directory: dir)
                let stem = OutputNaming.baseName(for: input)
                if parts.count == 1 { return done(parts[0].1, "\(stem) \(parts[0].0)", "pdf", c) }
                for (label, url) in parts {
                    try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("\(OutputNaming.fit(stem: stem, extension: "pdf")) \(label).pdf"))
                }
                return done(dir, "\(stem) split", "", c)
            }
            guard case .split(let o) = r.parameters else { throw ValidationError("Choose how to split.") }
            let format = Self.editableMediaFormat(item.format)
            let dir = try ws.subdirectory("parts")
            let parts = try await media.split(input, format: format, mode: o.mode, directory: dir, progress: c.progress)
            let stem = OutputNaming.baseName(for: input)
            for (i, url) in parts.enumerated() {
                try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("\(OutputNaming.fit(stem: stem, extension: format.preferredExtension)) part \(i + 1).\(format.preferredExtension)"))
            }
            return done(dir, "\(stem) parts", "", c)

        case .snapshot:
            let o: SnapshotOptions = { if case .snapshot(let o) = r.parameters { return o } ; return SnapshotOptions(mode: .count(1)) }()
            let dir = try ws.subdirectory("frames")
            let frames = try await media.snapshots(input, options: o, directory: dir, progress: c.progress)
            let stem = OutputNaming.baseName(for: input)
            if frames.count == 1 { return done(frames[0], "\(stem) frame", o.format.preferredExtension, c) }
            try nameChildren(in: dir, files: frames, base: stem)
            return done(dir, "\(stem) frames", "", c)

        case .join:
            let format = Self.editableMediaFormat(item.format)
            let out = ws.file("joined.\(format.preferredExtension)")
            try await media.join(r.inputs.map(\.url), format: format, output: out, progress: c.progress)
            return done(out, base, format.preferredExtension, c)

        case .merge:
            let out = ws.file("merged.pdf")
            try pdf.merge(r.inputs.map(\.url), output: out, progress: c.progress)
            return done(out, base, "pdf", c)

        case .organize:
            guard case .organize(let o) = r.parameters else { throw ValidationError("Arrange the pages first.") }
            let out = ws.file("organized.pdf")
            try pdf.organize(input, o, output: out)
            return done(out, base, "pdf", c)

        case .imagesToPDF:
            let o: ImagesToPDFOptions = { if case .imagesToPDF(let o) = r.parameters { return o } ; return ImagesToPDFOptions() }()
            var pages: [CGImage] = []
            for (i, it) in r.inputs.enumerated() {
                try Task.checkCancellation()
                pages.append(try images.load(it.url).image)
                c.progress(Double(i + 1) / Double(r.inputs.count) * 0.8)
            }
            let out = ws.file("images.pdf")
            try ImageEngine.writePDF(pages, to: out, dpi: 144, pageSize: o)
            let name = r.inputs.count == 1 ? OutputNaming.baseName(for: input) : OutputNaming.baseName(for: input, suffix: "and \(r.inputs.count - 1) more")
            return done(out, name, "pdf", c)

        case .collage:
            let o: CollageOptions = { if case .collage(let o) = r.parameters { return o } ; return CollageOptions() }()
            var pics: [CGImage] = []
            let cell = max(256, o.width / max(1, o.columns) * 2)
            for (i, it) in r.inputs.enumerated() {
                try Task.checkCancellation()
                pics.append(try images.load(it.url, maxPixelSize: cell).image)
                c.progress(Double(i + 1) / Double(r.inputs.count) * 0.7)
            }
            guard let image = ImageEngine.collage(pics, o) else { throw ImageError.encodeFailed("collage") }
            let out = ws.file("collage.\(o.format.preferredExtension)")
            try await images.write(image, to: out, format: o.format, quality: 0.9, workspace: ws)
            return done(out, "Collage", o.format.preferredExtension, c)

        case .readQR:
            var codes: [VisionEngine.Code] = []
            if item.kind == .pdf {
                let doc = try pdf.open(input)
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i), let img = PDFEngine.render(page, dpi: 200) { codes += try vision.codes(in: img) }
                    c.progress(Double(i + 1) / Double(doc.pageCount))
                }
            } else {
                codes = try vision.codes(in: try images.load(input).image)
            }
            guard !codes.isEmpty else { throw ValidationError("No QR or barcodes were found.") }
            let text = codes.map(\.payload).joined(separator: "\n") + "\n"
            let out = ws.file("codes.txt")
            try Data(text.utf8).write(to: out)
            return done(out, base, "txt", c)

        case .archive:
            let out = ws.file("archive.zip")
            try await archives.create(.zip, items: r.inputs.map(\.url), output: out)
            return done(out, r.inputs.count == 1 ? input.lastPathComponent : "Archive", "zip", c)

        case .rename:
            throw ValidationError("Rename is handled by the app.")
        }
    }

    func done(_ url: URL, _ base: String, _ ext: String, _ c: UnitContext, note: String? = nil) -> [StagedOutput] {
        c.progress(1)
        return [StagedOutput(url: url, base: base, ext: ext, note: note)]
    }

    func imageEdit(_ tool: ToolKind, _ r: UnitRequest, _ c: UnitContext, base: String) async throws -> [StagedOutput] {
        let item = r.primary
        let loaded = try images.load(item.url)
        var format = editableImageFormat(item.format)
        let image: CGImage?
        switch (tool, r.parameters) {
        case (.resize, .resize(let o)):
            let (w, h) = ImageEngine.targetSize(for: o.mode, width: loaded.width, height: loaded.height)
            image = ImageEngine.resized(loaded.image, width: w, height: h)
        case (.crop, .crop(let o)):
            var cropped = ImageEngine.cropped(loaded.image, to: o.rect)
            if let w = o.outputWidth, let h = o.outputHeight, let img = cropped { cropped = ImageEngine.resized(img, width: w, height: h) }
            image = cropped
        case (.rotate, let p):
            let o: RotateOptions = { if case .rotate(let o) = p { return o } ; return RotateOptions() }()
            image = ImageEngine.rotated(loaded.image, o)
        case (.adjust, .adjust(let o)):
            image = ImageEngine.adjusted(loaded.image, o)
        case (.annotate, .annotate(let o)):
            image = ImageEngine.annotated(loaded.image, o)
        case (.frame, let p):
            let o: FrameOptions = { if case .frame(let o) = p { return o } ; return FrameOptions() }()
            image = ImageEngine.framed(loaded.image, o)
            // Rounded corners on a transparent canvas need an alpha channel.
            if case .transparent = o.background, ![FileFormat.png, .heic, .tiff, .webp, .avif].contains(format) { format = .png }
        case (.redact, .redact(let o)):
            image = ImageEngine.redacted(loaded.image, o)
        default:
            throw ValidationError("Missing settings for this tool.")
        }
        guard let image else { throw ImageError.encodeFailed(format.label) }
        let out = c.workspace.file("edit.\(format.preferredExtension)")
        // Redaction must not leak the original via a preview thumbnail or location data.
        var props = ImageEngine.carriedProperties(loaded.properties)
        if tool == .redact { props.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        try await images.write(image, to: out, format: format, quality: 0.92, properties: props, workspace: c.workspace)
        return done(out, base, format.preferredExtension, c)
    }
}
