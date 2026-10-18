import Foundation

/// One file or folder the user dragged or chose.
public struct DroppedItem: Sendable, Hashable, Codable {
    public let url: URL
    public let format: FileFormat?
    public let kind: FileKind
    public let byteSize: Int64
    public let isDirectory: Bool

    public init(url: URL, format: FileFormat?, kind: FileKind, byteSize: Int64, isDirectory: Bool) {
        self.url = url
        self.format = format
        self.kind = kind
        self.byteSize = byteSize
        self.isDirectory = isDirectory
    }

    /// Inspects the file system. Package directories (.rtfd, .pages, .key, .numbers) count as files.
    public static func inspect(_ url: URL) -> DroppedItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        let format = FileFormat.detect(url)
        let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false) && format == nil
        let kind: FileKind = isDirectory ? .folder : (format?.kind ?? .other)
        let size = Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
        return DroppedItem(url: url, format: format, kind: kind, byteSize: size, isDirectory: isDirectory)
    }
}

/// The set of items an operation would act on.
public struct Selection: Sendable, Hashable {
    public let items: [DroppedItem]

    public init(items: [DroppedItem]) {
        // Keep drop order, drop duplicates.
        var seen = Set<URL>()
        self.items = items.filter { seen.insert($0.url.standardizedFileURL).inserted }
    }

    public init(urls: [URL]) {
        self.init(items: urls.map(DroppedItem.inspect))
    }

    public var urls: [URL] { items.map(\.url) }
    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    public var isMulti: Bool { items.count > 1 }
    public var kinds: Set<FileKind> { Set(items.map(\.kind)) }
    public var formats: Set<FileFormat> { Set(items.compactMap(\.format)) }
    public var isMixed: Bool { kinds.count > 1 }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteSize } }

    /// The single kind shared by every item, if any.
    public var uniformKind: FileKind? { kinds.count == 1 ? kinds.first : nil }

    /// Human summary for the wheel hub, e.g. "3 Images · 4.2 MB".
    public var summary: String {
        guard let first = items.first else { return "Nothing selected" }
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        if items.count == 1 {
            let label = first.isDirectory ? "Folder" : (first.format?.label ?? first.kind.displayName)
            return first.isDirectory ? label : "\(label) · \(size)"
        }
        if let kind = uniformKind {
            return "\(items.count) \(kind.pluralName) · \(size)"
        }
        return "\(items.count) items · \(size)"
    }
}

extension FileKind {
    public var pluralName: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio files"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .slides: "Presentations"
        case .spreadsheet: "Spreadsheets"
        case .subtitle: "Subtitle files"
        case .archive: "Archives"
        case .folder: "Folders"
        case .other: "Files"
        }
    }
}
