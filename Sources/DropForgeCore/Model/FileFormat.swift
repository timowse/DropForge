import Foundation
import UniformTypeIdentifiers

/// Broad family of a file. Decides which wheel segments make sense.
public enum FileKind: String, Sendable, CaseIterable, Codable {
    case image, video, audio, pdf, document, slides, spreadsheet, subtitle, archive, folder, other

    public var displayName: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .document: "Document"
        case .slides: "Presentation"
        case .spreadsheet: "Spreadsheet"
        case .subtitle: "Subtitles"
        case .archive: "Archive"
        case .folder: "Folder"
        case .other: "File"
        }
    }

    public var symbolName: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .slides: "rectangle.on.rectangle"
        case .spreadsheet: "tablecells"
        case .subtitle: "captions.bubble"
        case .archive: "archivebox"
        case .folder: "folder"
        case .other: "doc"
        }
    }
}

/// Every concrete format DropForge knows about, as input and/or output.
public enum FileFormat: String, Sendable, CaseIterable, Codable, Hashable {
    // Images
    case jpeg, png, webp, heic, tiff, avif, gif, bmp, svg, pdf
    // Video
    case mp4, mov, mkv, webm, avi, wmv, m4v
    // Audio
    case mp3, m4a, aac, wav, flac, ogg, opus, aiff, wma
    // Documents
    case txt, md, rtf, rtfd, html, docx, doc, odt, epub, pages
    // Slides
    case ppt, pptx, odp, key
    // Spreadsheets
    case xls, xlsx, ods, csv, tsv, numbers
    // Subtitles
    case srt, vtt
    // Archives
    case zip, tar, gz, tgz, rar, sevenZip

    public var kind: FileKind {
        switch self {
        case .jpeg, .png, .webp, .heic, .tiff, .avif, .gif, .bmp, .svg: .image
        case .pdf: .pdf
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v: .video
        case .mp3, .m4a, .aac, .wav, .flac, .ogg, .opus, .aiff, .wma: .audio
        case .txt, .md, .rtf, .rtfd, .html, .docx, .doc, .odt, .epub, .pages: .document
        case .ppt, .pptx, .odp, .key: .slides
        case .xls, .xlsx, .ods, .csv, .tsv, .numbers: .spreadsheet
        case .srt, .vtt: .subtitle
        case .zip, .tar, .gz, .tgz, .rar, .sevenZip: .archive
        }
    }

    /// Preferred file extension for outputs.
    public var preferredExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tgz: "tar.gz"
        case .sevenZip: "7z"
        case .aiff: "aiff"
        default: rawValue
        }
    }

    /// All extensions recognised for input (lower-case, without dot).
    public var extensions: [String] {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe", "jfif"]
        case .tiff: ["tif", "tiff"]
        case .heic: ["heic", "heif", "hif"]
        case .html: ["html", "htm", "xhtml"]
        case .md: ["md", "markdown", "mdown", "mkd"]
        case .txt: ["txt", "text"]
        case .aiff: ["aiff", "aif", "aifc"]
        case .m4a: ["m4a", "m4b"]
        case .ogg: ["ogg", "oga"]
        case .mp4: ["mp4"]
        case .mkv: ["mkv"]
        case .tgz: ["tgz", "tar.gz"]
        case .gz: ["gz", "gzip"]
        case .sevenZip: ["7z"]
        case .vtt: ["vtt", "webvtt"]
        default: [rawValue]
        }
    }

    /// Short label used on wheel segments.
    public var label: String {
        switch self {
        case .jpeg: "JPG"
        case .tgz: "TAR.GZ"
        case .sevenZip: "7Z"
        case .md: "Markdown"
        case .txt: "Text"
        case .pages: "Pages"
        case .numbers: "Numbers"
        case .key: "Keynote"
        default: rawValue.uppercased()
        }
    }

    /// Formats DropForge can read but never writes.
    public var isInputOnly: Bool {
        switch self {
        case .svg, .avi, .wmv, .wma, .rar, .sevenZip, .doc, .xls, .ppt, .rtfd, .key, .pages, .numbers, .aac, .m4v:
            true
        default:
            false
        }
    }

    public var utType: UTType? {
        UTType(filenameExtension: preferredExtension.components(separatedBy: ".").last ?? preferredExtension)
    }

    /// Detects a format from a URL (by extension; packages such as .rtfd/.pages/.key count as files).
    public static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return .tgz }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return extensionIndex[ext]
    }

    private static let extensionIndex: [String: FileFormat] = {
        var map: [String: FileFormat] = [:]
        for format in FileFormat.allCases {
            for ext in format.extensions where !ext.contains(".") {
                if map[ext] == nil { map[ext] = format }
            }
        }
        return map
    }()
}
