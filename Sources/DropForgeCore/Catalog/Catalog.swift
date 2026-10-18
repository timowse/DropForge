import Foundation

/// The static table of what DropForge can do. Pure data; `CapabilityResolver` applies it to a selection.
public enum Catalog {
    // MARK: Conversion routes

    static let imageTargets: [FileFormat] = [.jpeg, .png, .webp, .heic, .avif, .tiff, .gif, .bmp, .pdf]
    static let videoTargets: [FileFormat] = [.mp4, .mov, .webm, .mkv, .gif, .mp3, .m4a, .wav]
    static let audioTargets: [FileFormat] = [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus]
    static let pdfTargets: [FileFormat] = [.jpeg, .png, .txt, .md, .docx, .html, .rtf, .epub, .pptx]
    static let documentTargets: [FileFormat] = [.pdf, .docx, .md, .txt, .html, .rtf, .odt, .epub]
    static let pagesTargets: [FileFormat] = [.pdf, .docx, .txt, .epub]
    static let slideTargets: [FileFormat] = [.pdf, .jpeg, .png, .pptx]
    static let spreadsheetTargets: [FileFormat] = [.xlsx, .csv, .tsv, .ods, .pdf]
    static let archiveTargets: [FileFormat] = [.zip, .tar, .tgz]

    /// Targets for one source format, in wheel order. `nil` source = folder or unknown file.
    public static func conversionTargets(for source: FileFormat?) -> [ConversionTarget] {
        guard let source else { return archiveTargets.map { .format($0) } }
        var formats: [FileFormat]
        switch source.kind {
        case .image:
            formats = imageTargets
            if source == .gif { formats.append(.mp4) ; formats.append(.webm) }
        case .video: formats = videoTargets
        case .audio: formats = audioTargets
        case .pdf: formats = pdfTargets
        case .document: formats = source == .pages ? pagesTargets : documentTargets
        case .slides: formats = slideTargets
        case .spreadsheet: formats = spreadsheetTargets
        case .subtitle: formats = [.srt, .vtt, .txt]
        case .archive:
            return [.extract] + archiveTargets.filter { $0 != source }.map { .format($0) }
        case .folder, .other: formats = archiveTargets
        }
        return formats.filter { $0 != source && !$0.isInputOnly }.map { .format($0) }
    }

    /// Engines able to perform `source → target`, in preference order.
    public static func engines(from source: FileFormat?, to target: ConversionTarget) -> [EngineRequirement] {
        guard case .format(let out) = target else { return [.bsdtar] }
        guard let source else { return out == .zip ? [.native] : [.bsdtar] }
        if out.kind == .archive && source.kind != .archive {
            return out == .zip ? [.native] : [.bsdtar]
        }
        switch source.kind {
        case .image:
            if out == .webp { return [.cwebp] }
            if out.kind == .video { return [.ffmpeg] }
            return [.native]
        case .video, .audio:
            return [.ffmpeg]
        case .pdf:
            return [.native]
        case .document:
            if source == .pages { return [.pages, .libreOffice] }
            switch source {
            case .docx, .doc, .odt:
                return out == .pdf ? [.libreOffice, .native] : [.native]
            default:
                return [.native]
            }
        case .slides:
            if source == .key { return [.keynote, .libreOffice] }
            return [.libreOffice, .keynote]
        case .spreadsheet:
            if source == .numbers { return [.numbers, .libreOffice] }
            if (source == .csv || source == .tsv) && (out == .csv || out == .tsv) { return [.native] }
            return [.libreOffice, .numbers]
        case .subtitle:
            return [.native]
        case .archive:
            return [.bsdtar]
        case .folder, .other:
            return [.native]
        }
    }

    public static func conversionDescriptor(_ target: ConversionTarget, source: FileFormat?, combined: Bool) -> OperationDescriptor {
        switch target {
        case .extract:
            return OperationDescriptor(kind: .convert(.extract), title: "Extract archive", shortTitle: "Extract",
                                       symbolName: "archivebox.circle", engines: [.bsdtar])
        case .format(let out):
            let engines = engines(from: source, to: target)
            let isArchive = out.kind == .archive
            let title: String
            if isArchive {
                title = "Archive as \(out.label)"
            } else if source?.kind == .video && out.kind == .audio {
                title = "Extract audio as \(out.label)"
            } else if source?.kind == .pdf && (out == .jpeg || out == .png) {
                title = "Export pages as \(out.label)"
            } else {
                title = "Convert to \(out.label)"
            }
            return OperationDescriptor(kind: .convert(target), title: title, shortTitle: out.label,
                                       symbolName: symbol(for: out), engines: engines,
                                       batchMode: isArchive && combined ? .combined : .perItem)
        }
    }

    static func symbol(for format: FileFormat) -> String {
        switch format.kind {
        case .image: "photo"
        case .video: format == .gif ? "sparkles.rectangle.stack" : "film"
        case .audio: "music.note"
        case .pdf: "doc.richtext"
        case .document: format == .md ? "number" : (format == .epub ? "book" : "doc.text")
        case .slides: "rectangle.on.rectangle"
        case .spreadsheet: "tablecells"
        case .subtitle: "captions.bubble"
        case .archive: "archivebox"
        case .folder, .other: "doc"
        }
    }

    // MARK: Tools

    public static func tool(_ kind: ToolKind) -> OperationDescriptor {
        func d(_ title: String, _ short: String, _ symbol: String, _ engines: [EngineRequirement] = [.native],
               editor: Bool = true, batch: BatchMode = .perItem, min: Int = 1, max: Int? = nil) -> OperationDescriptor {
            OperationDescriptor(kind: .tool(kind), title: title, shortTitle: short, symbolName: symbol, engines: engines,
                                needsEditor: editor, batchMode: batch, minItems: min, maxItems: max)
        }
        switch kind {
        case .compress: return d("Compress", "Compress", "arrow.down.right.and.arrow.up.left")
        case .resize: return d("Resize", "Resize", "arrow.up.left.and.down.right.magnifyingglass")
        case .crop: return d("Crop", "Crop", "crop")
        case .rotate: return d("Rotate or flip", "Rotate", "rotate.right")
        case .adjust: return d("Adjust colour and light", "Adjust", "dial.medium", max: 1)
        case .annotate: return d("Annotate", "Annotate", "pencil.tip.crop.circle", max: 1)
        case .frame: return d("Background and frame", "Frame", "square.on.square.dashed")
        case .redact: return d("Redact", "Redact", "eye.slash", max: 1)
        case .metadata: return d("View or edit metadata", "Metadata", "info.circle", max: 1)
        case .stripMetadata: return d("Remove metadata", "Strip info", "eraser", editor: false)
        case .trim: return d("Trim", "Trim", "scissors", [.ffmpeg], max: 1)
        case .speed: return d("Change speed", "Speed", "gauge.with.dots.needle.67percent", [.ffmpeg])
        case .split: return d("Split", "Split", "square.split.2x1", [.ffmpeg])
        case .join: return d("Join in order", "Join", "link", [.ffmpeg], editor: false, batch: .combined, min: 2)
        case .snapshot: return d("Snapshots", "Snapshot", "camera", [.ffmpeg])
        case .mute: return d("Remove audio track", "Mute", "speaker.slash", [.ffmpeg], editor: false)
        case .normalize: return d("Normalize loudness", "Normalize", "speaker.wave.2", [.ffmpeg])
        case .channels: return d("Change channels", "Channels", "headphones", [.ffmpeg])
        case .bleep: return d("Bleep intervals", "Bleep", "exclamationmark.bubble", [.ffmpeg], max: 1)
        case .merge: return d("Merge in order", "Merge", "doc.on.doc", editor: false, batch: .combined, min: 2)
        case .organize: return d("Reorder, rotate or delete pages", "Pages", "square.grid.3x3", max: 1)
        case .imagesToPDF: return d("Combine into PDF", "To PDF", "doc.badge.plus", batch: .combined)
        case .collage: return d("Make a collage", "Collage", "square.grid.2x2", batch: .combined, min: 2)
        case .readQR: return d("Read QR codes", "Read QR", "qrcode.viewfinder", editor: false)
        case .rename: return d("Rename in batch", "Rename", "character.cursor.ibeam", batch: .combined)
        case .archive: return d("Make a ZIP archive", "ZIP", "archivebox", editor: false, batch: .combined)
        }
    }

    /// Tools per kind, in wheel order (most used first).
    public static func tools(for kind: FileKind) -> [ToolKind] {
        switch kind {
        case .image: [.compress, .crop, .resize, .adjust, .annotate, .redact, .frame, .metadata,
                      .rotate, .readQR, .stripMetadata, .imagesToPDF, .collage, .rename, .archive]
        case .video: [.compress, .trim, .crop, .speed, .split, .snapshot, .join, .metadata,
                      .stripMetadata, .mute, .rename, .archive]
        case .audio: [.compress, .trim, .normalize, .channels, .bleep, .join, .metadata, .stripMetadata, .speed,
                      .rename, .archive]
        case .pdf: [.compress, .merge, .split, .organize, .redact, .metadata, .stripMetadata, .readQR,
                    .rename, .archive]
        case .document, .slides, .spreadsheet, .subtitle, .archive, .folder, .other: [.rename, .archive]
        }
    }

    // MARK: Actions

    public static func action(_ kind: ActionKind) -> OperationDescriptor {
        func d(_ title: String, _ short: String, _ symbol: String, _ engines: [EngineRequirement] = [.native]) -> OperationDescriptor {
            OperationDescriptor(kind: .action(kind), title: title, shortTitle: short, symbolName: symbol, engines: engines,
                                needsEditor: false, batchMode: .combined)
        }
        switch kind {
        case .airdrop: return d("Send with AirDrop", "AirDrop", "airplayaudio")
        case .float: return d("Keep on the shelf", "Shelf", "tray.and.arrow.down")
        case .copyTo: return d("Copy to folder…", "Copy to", "doc.on.doc")
        case .moveTo: return d("Move to folder…", "Move to", "folder")
        case .copyPath: return d("Copy path", "Copy path", "link")
        case .terminal: return d("Open in Terminal", "Terminal", "terminal")
        case .iterm: return d("Open in iTerm", "iTerm", "apple.terminal", [.iTerm])
        }
    }

    public static let actionOrder: [ActionKind] = [.airdrop, .float, .copyTo, .moveTo, .copyPath, .terminal, .iterm]
}
