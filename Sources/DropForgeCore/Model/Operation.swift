import Foundation

/// The three wheels.
public enum OperationCategory: String, Sendable, CaseIterable, Codable, Hashable {
    case convert, tools, actions

    public var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }

    public var symbolName: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .tools: "slider.horizontal.3"
        case .actions: "square.and.arrow.up.on.square"
        }
    }
}

/// An engine or helper app an operation depends on. An operation lists alternatives; any one suffices.
public enum EngineRequirement: String, Sendable, CaseIterable, Codable, Hashable {
    case native, ffmpeg, cwebp, libreOffice, keynote, pages, numbers, iTerm, bsdtar

    public var displayName: String {
        switch self {
        case .native: "macOS"
        case .ffmpeg: "FFmpeg"
        case .cwebp: "WebP encoder"
        case .libreOffice: "LibreOffice"
        case .keynote: "Keynote"
        case .pages: "Pages"
        case .numbers: "Numbers"
        case .iTerm: "iTerm"
        case .bsdtar: "bsdtar"
        }
    }

    /// Plain explanation shown when the engine is missing.
    public var missingExplanation: String {
        switch self {
        case .native: "This needs a newer version of macOS."
        case .ffmpeg: "The bundled FFmpeg helper could not be found. Reinstall DropForge."
        case .cwebp: "The bundled WebP encoder could not be found. Reinstall DropForge."
        case .libreOffice: "Install the free LibreOffice app to enable Office conversions."
        case .keynote: "Install Keynote from the App Store to enable this export."
        case .pages: "Install Pages from the App Store to enable this export."
        case .numbers: "Install Numbers from the App Store to enable this export."
        case .iTerm: "iTerm is not installed."
        case .bsdtar: "The system archive tool is missing."
        }
    }
}

public enum ToolKind: String, Sendable, CaseIterable, Codable, Hashable {
    case compress, resize, crop, rotate, adjust, annotate, frame, redact
    case metadata, stripMetadata, trim, speed, split, join, snapshot, mute
    case normalize, channels, bleep, merge, organize, imagesToPDF, collage, readQR, rename, archive
}

public enum ActionKind: String, Sendable, CaseIterable, Codable, Hashable {
    case airdrop, float, copyTo, moveTo, copyPath, terminal, iterm
}

public enum ConversionTarget: Sendable, Hashable, Codable {
    case format(FileFormat)
    case extract
}

public enum OperationKind: Sendable, Hashable {
    case convert(ConversionTarget)
    case tool(ToolKind)
    case action(ActionKind)

    public var category: OperationCategory {
        switch self {
        case .convert: .convert
        case .tool: .tools
        case .action: .actions
        }
    }
}

/// How a batch is processed.
public enum BatchMode: Sendable, Hashable {
    /// One unit of work per input item.
    case perItem
    /// All inputs feed a single output (merge, join, collage, archive of many items).
    case combined
}

/// A segment on a wheel / row in the picker.
public struct OperationDescriptor: Sendable, Hashable, Identifiable {
    public let kind: OperationKind
    public let title: String
    public let shortTitle: String
    public let symbolName: String
    /// Alternatives; any available one can perform the operation. Ordered by preference.
    public let engines: [EngineRequirement]
    public let needsEditor: Bool
    public let batchMode: BatchMode
    public let minItems: Int
    public let maxItems: Int?

    public var id: String {
        switch kind {
        case .convert(.format(let f)): "convert.\(f.rawValue)"
        case .convert(.extract): "convert.extract"
        case .tool(let t): "tool.\(t.rawValue)"
        case .action(let a): "action.\(a.rawValue)"
        }
    }

    public var category: OperationCategory { kind.category }

    public init(kind: OperationKind, title: String, shortTitle: String, symbolName: String,
                engines: [EngineRequirement], needsEditor: Bool = false, batchMode: BatchMode = .perItem,
                minItems: Int = 1, maxItems: Int? = nil) {
        self.kind = kind
        self.title = title
        self.shortTitle = shortTitle
        self.symbolName = symbolName
        self.engines = engines
        self.needsEditor = needsEditor
        self.batchMode = batchMode
        self.minItems = minItems
        self.maxItems = maxItems
    }

    /// The output format, for conversions.
    public var outputFormat: FileFormat? {
        if case .convert(.format(let f)) = kind { return f }
        return nil
    }
}

/// An operation that exists for this selection but cannot run right now, with the reason.
public struct UnavailableOperation: Sendable, Hashable {
    public let descriptor: OperationDescriptor
    public let reason: String
}
