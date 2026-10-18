import Foundation

/// A rectangle in unit coordinates (0...1), origin top-left. Resolution independent so one crop can
/// apply to a batch and to video via ffmpeg expressions.
public struct UnitRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    public var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000_001 && y + height <= 1.000_001
    }

    /// Pixel rectangle (top-left origin) for an image of the given size, clamped and at least 1×1.
    public func pixelRect(width w: Int, height h: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let px = max(0, min(w - 1, Int((x * Double(w)).rounded())))
        let py = max(0, min(h - 1, Int((y * Double(h)).rounded())))
        let pw = max(1, min(w - px, Int((width * Double(w)).rounded())))
        let ph = max(1, min(h - py, Int((height * Double(h)).rounded())))
        return (px, py, pw, ph)
    }
}

public struct RGBAColor: Sendable, Hashable, Codable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

public struct CompressOptions: Sendable, Hashable, Codable {
    public enum Preset: String, Sendable, Hashable, Codable, CaseIterable {
        case high, balanced, small
        public var title: String {
            switch self {
            case .high: "High quality"
            case .balanced: "Balanced"
            case .small: "Smallest"
            }
        }
    }
    public enum Mode: Sendable, Hashable, Codable {
        case preset(Preset)
        /// Target output size as a percentage of the input size (1...99).
        case percent(Int)
        /// Target output size in bytes.
        case targetBytes(Int64)
    }
    public var mode: Mode
    /// Longest edge in pixels for images/video; nil keeps dimensions.
    public var maxDimension: Int?

    public init(mode: Mode = .preset(.balanced), maxDimension: Int? = nil) {
        self.mode = mode
        self.maxDimension = maxDimension
    }
}

public struct ResizeOptions: Sendable, Hashable, Codable {
    public enum Mode: Sendable, Hashable, Codable {
        case scale(percent: Int)
        case fit(width: Int, height: Int)
        case exact(width: Int, height: Int)
    }
    public var mode: Mode
    public init(mode: Mode) { self.mode = mode }
}

public struct CropOptions: Sendable, Hashable, Codable {
    public var rect: UnitRect
    /// Optional output size after the crop.
    public var outputWidth: Int?
    public var outputHeight: Int?
    public init(rect: UnitRect, outputWidth: Int? = nil, outputHeight: Int? = nil) {
        self.rect = rect; self.outputWidth = outputWidth; self.outputHeight = outputHeight
    }
}

public struct RotateOptions: Sendable, Hashable, Codable {
    /// Clockwise quarter turns (0...3).
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public init(quarterTurns: Int = 1, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}

public struct AdjustOptions: Sendable, Hashable, Codable {
    /// EV stops, -2...2.
    public var exposure: Double = 0
    /// -1...1.
    public var contrast: Double = 0
    /// -1...1.
    public var saturation: Double = 0
    /// -1...1 (cool ... warm).
    public var warmth: Double = 0
    /// 0...1.
    public var sharpness: Double = 0
    /// 0...1 highlights recovery.
    public var highlights: Double = 0
    /// 0...1 shadow lift.
    public var shadows: Double = 0
    public init() {}
    public var isIdentity: Bool { self == AdjustOptions() }
}

public struct Annotation: Sendable, Hashable, Codable, Identifiable {
    public enum Shape: String, Sendable, Hashable, Codable, CaseIterable {
        case rectangle, ellipse, arrow, line, text, highlight
    }
    public var id: UUID
    public var shape: Shape
    /// Bounds in unit coordinates (top-left origin). Lines and arrows run corner to corner.
    public var rect: UnitRect
    public var color: RGBAColor
    /// Line width relative to the image's shorter side.
    public var lineWidth: Double
    public var text: String
    /// Lines/arrows: true when the line rises from the left edge (bottom-left → top-right).
    public var startAtBottom: Bool
    /// Arrows: true when the head sits at the left end instead of the right end.
    public var reversed: Bool
    public init(id: UUID = UUID(), shape: Shape, rect: UnitRect, color: RGBAColor, lineWidth: Double = 0.006,
                text: String = "", startAtBottom: Bool = false, reversed: Bool = false) {
        self.id = id; self.shape = shape; self.rect = rect; self.color = color
        self.lineWidth = lineWidth; self.text = text; self.startAtBottom = startAtBottom; self.reversed = reversed
    }
}

public struct AnnotationOptions: Sendable, Hashable, Codable {
    public var annotations: [Annotation]
    public init(annotations: [Annotation]) { self.annotations = annotations }
}

public struct FrameOptions: Sendable, Hashable, Codable {
    public enum Background: Sendable, Hashable, Codable {
        case solid(RGBAColor)
        case gradient(RGBAColor, RGBAColor)
        case transparent
    }
    public var background: Background
    /// Padding relative to the shorter side, 0...0.5.
    public var padding: Double
    /// Corner radius relative to the shorter side of the image, 0...0.5.
    public var cornerRadius: Double
    public var shadow: Bool
    /// Optional output aspect ratio (width / height) of the canvas, e.g. 1 for square posts.
    public var canvasAspect: Double?
    public init(background: Background = .solid(.white), padding: Double = 0.08, cornerRadius: Double = 0.03,
                shadow: Bool = true, canvasAspect: Double? = nil) {
        self.background = background; self.padding = padding; self.cornerRadius = cornerRadius
        self.shadow = shadow; self.canvasAspect = canvasAspect
    }
}

public struct RedactOptions: Sendable, Hashable, Codable {
    public enum Style: String, Sendable, Hashable, Codable, CaseIterable {
        case solid, pixelate, blur
    }
    public var regions: [UnitRect]
    public var style: Style
    /// For PDFs: page index → regions. When non-empty, `regions` is ignored for PDFs.
    public var pageRegions: [Int: [UnitRect]]
    public init(regions: [UnitRect] = [], style: Style = .solid, pageRegions: [Int: [UnitRect]] = [:]) {
        self.regions = regions; self.style = style; self.pageRegions = pageRegions
    }
}

public struct MetadataEdit: Sendable, Hashable, Codable {
    /// Common fields; nil leaves unchanged, empty string removes.
    public var title: String?
    public var author: String?
    public var comment: String?
    public var keywords: String?
    public var removeAll: Bool
    public var removeLocation: Bool
    public init(title: String? = nil, author: String? = nil, comment: String? = nil, keywords: String? = nil,
                removeAll: Bool = false, removeLocation: Bool = false) {
        self.title = title; self.author = author; self.comment = comment; self.keywords = keywords
        self.removeAll = removeAll; self.removeLocation = removeLocation
    }
    public var hasEdits: Bool { title != nil || author != nil || comment != nil || keywords != nil }
}

/// A time interval in seconds.
public struct TimeSpan: Sendable, Hashable, Codable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
}

public struct SplitOptions: Sendable, Hashable, Codable {
    public enum Mode: Sendable, Hashable, Codable {
        /// Cut at these timestamps (seconds).
        case atTimes([Double])
        /// N equal parts.
        case equalParts(Int)
        /// Fixed segment length in seconds.
        case every(Double)
    }
    public var mode: Mode
    public init(mode: Mode) { self.mode = mode }
}

public struct SnapshotOptions: Sendable, Hashable, Codable {
    public enum Mode: Sendable, Hashable, Codable {
        case atTimes([Double])
        case every(Double)
        case count(Int)
    }
    public var mode: Mode
    public var format: FileFormat
    public init(mode: Mode, format: FileFormat = .png) { self.mode = mode; self.format = format }
}

public struct NormalizeOptions: Sendable, Hashable, Codable {
    /// Integrated loudness target in LUFS.
    public var targetLUFS: Double
    public var truePeak: Double
    public init(targetLUFS: Double = -16, truePeak: Double = -1.5) { self.targetLUFS = targetLUFS; self.truePeak = truePeak }
}

public enum ChannelMode: String, Sendable, Hashable, Codable, CaseIterable {
    case mono, stereo, swap, leftOnly, rightOnly
    public var title: String {
        switch self {
        case .mono: "Mix to mono"
        case .stereo: "Make stereo"
        case .swap: "Swap left and right"
        case .leftOnly: "Keep left channel"
        case .rightOnly: "Keep right channel"
        }
    }
}

public struct BleepOptions: Sendable, Hashable, Codable {
    public var intervals: [TimeSpan]
    /// Tone frequency in Hz; 0 means silence instead of a tone.
    public var frequency: Double
    public init(intervals: [TimeSpan], frequency: Double = 1000) { self.intervals = intervals; self.frequency = frequency }
}

public struct PageOrganization: Sendable, Hashable, Codable {
    public struct Page: Sendable, Hashable, Codable {
        public var sourceIndex: Int
        /// Clockwise quarter turns added to the page.
        public var rotation: Int
        public init(sourceIndex: Int, rotation: Int = 0) { self.sourceIndex = sourceIndex; self.rotation = rotation }
    }
    /// Output pages in order; omitted source pages are deleted.
    public var pages: [Page]
    public init(pages: [Page]) { self.pages = pages }
}

public struct PDFSplitOptions: Sendable, Hashable, Codable {
    public enum Mode: Sendable, Hashable, Codable {
        case everyPage
        case everyN(Int)
        /// Ranges like "1-3, 4, 5-9" (1-based); each range becomes one file.
        case ranges(String)
    }
    public var mode: Mode
    public init(mode: Mode) { self.mode = mode }
}

public struct ImagesToPDFOptions: Sendable, Hashable, Codable {
    public enum PageSize: String, Sendable, Hashable, Codable, CaseIterable {
        case fitImage, a4, letter
        public var title: String {
            switch self {
            case .fitImage: "Fit each image"
            case .a4: "A4"
            case .letter: "US Letter"
            }
        }
        /// Points (portrait).
        public var points: (Double, Double)? {
            switch self {
            case .fitImage: nil
            case .a4: (595.28, 841.89)
            case .letter: (612, 792)
            }
        }
    }
    public var pageSize: PageSize
    /// Margin in points.
    public var margin: Double
    public var landscape: Bool
    public init(pageSize: PageSize = .fitImage, margin: Double = 0, landscape: Bool = false) {
        self.pageSize = pageSize; self.margin = margin; self.landscape = landscape
    }
}

public struct CollageOptions: Sendable, Hashable, Codable {
    public var columns: Int
    /// Output width in pixels.
    public var width: Int
    /// Cell aspect (width / height). nil keeps each image's aspect within a uniform row height.
    public var cellAspect: Double?
    public var spacing: Int
    public var background: RGBAColor
    public var cornerRadius: Int
    public var format: FileFormat
    public init(columns: Int = 3, width: Int = 2400, cellAspect: Double? = 1, spacing: Int = 16,
                background: RGBAColor = .white, cornerRadius: Int = 0, format: FileFormat = .jpeg) {
        self.columns = columns; self.width = width; self.cellAspect = cellAspect; self.spacing = spacing
        self.background = background; self.cornerRadius = cornerRadius; self.format = format
    }
}

public struct ArchiveOptions: Sendable, Hashable, Codable {
    public var format: FileFormat
    public init(format: FileFormat = .zip) { self.format = format }
}

/// Parameters chosen in an editor (or defaults for one-shot operations).
public enum ToolParameters: Sendable, Hashable {
    case none
    case compress(CompressOptions)
    case resize(ResizeOptions)
    case crop(CropOptions)
    case rotate(RotateOptions)
    case adjust(AdjustOptions)
    case annotate(AnnotationOptions)
    case frame(FrameOptions)
    case redact(RedactOptions)
    case metadata(MetadataEdit)
    case trim(TimeSpan)
    case speed(Double)
    case split(SplitOptions)
    case snapshot(SnapshotOptions)
    case normalize(NormalizeOptions)
    case channels(ChannelMode)
    case bleep(BleepOptions)
    case organize(PageOrganization)
    case pdfSplit(PDFSplitOptions)
    case imagesToPDF(ImagesToPDFOptions)
    case collage(CollageOptions)
    case rename(RenamePattern)
    case archive(ArchiveOptions)
    case destination(URL)
}
