import AppKit
import DropForgeCore

/// Finds helper executables and optional apps. Bundled helpers win; Homebrew is a development fallback.
public struct EngineLocator: Sendable {
    public let helperDirectories: [URL]
    public let applicationLookup: @Sendable (String) -> URL?

    public init(helperDirectories: [URL]? = nil,
                applicationLookup: @escaping @Sendable (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        if let helperDirectories {
            self.helperDirectories = helperDirectories
        } else {
            var dirs: [URL] = []
            if let override = ProcessInfo.processInfo.environment["DROPFORGE_HELPERS"] {
                dirs.append(URL(fileURLWithPath: override))
            }
            dirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true))
            dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
            dirs.append(URL(fileURLWithPath: "/usr/local/bin"))
            self.helperDirectories = dirs
        }
        self.applicationLookup = applicationLookup
    }

    public func helper(_ name: String) -> URL? {
        for dir in helperDirectories {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public var ffmpeg: URL? { helper("ffmpeg") }
    public var ffprobe: URL? { helper("ffprobe") }
    public var cwebp: URL? { helper("cwebp") }

    public static let bundleIDs: [EngineRequirement: String] = [
        .libreOffice: "org.libreoffice.script",
        .keynote: "com.apple.iWork.Keynote",
        .pages: "com.apple.iWork.Pages",
        .numbers: "com.apple.iWork.Numbers",
        .iTerm: "com.googlecode.iterm2",
    ]

    public func application(_ engine: EngineRequirement) -> URL? {
        guard let id = Self.bundleIDs[engine] else { return nil }
        if let url = applicationLookup(id) { return url }
        if engine == .libreOffice {
            let fallback = URL(fileURLWithPath: "/Applications/LibreOffice.app")
            if FileManager.default.fileExists(atPath: fallback.path) { return fallback }
        }
        return nil
    }

    public var soffice: URL? {
        application(.libreOffice).map { $0.appendingPathComponent("Contents/MacOS/soffice") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// Detects everything now. Cheap enough to call when the wheel opens.
    public func availability() -> EngineAvailability {
        var set: Set<EngineRequirement> = [.native]
        if ffmpeg != nil && ffprobe != nil { set.insert(.ffmpeg) }
        if cwebp != nil { set.insert(.cwebp) }
        if FileManager.default.isExecutableFile(atPath: ArchiveCommands.bsdtar.path) { set.insert(.bsdtar) }
        if soffice != nil { set.insert(.libreOffice) }
        for engine in [EngineRequirement.keynote, .pages, .numbers, .iTerm] where application(engine) != nil {
            set.insert(engine)
        }
        return EngineAvailability(available: set)
    }

    /// Human-readable report for Settings and the smoke test.
    public func report() -> [(EngineRequirement, String)] {
        EngineRequirement.allCases.map { engine in
            let where_: String
            switch engine {
            case .native: where_ = "built into macOS"
            case .ffmpeg: where_ = ffmpeg?.path ?? "missing"
            case .cwebp: where_ = cwebp?.path ?? "missing"
            case .bsdtar: where_ = ArchiveCommands.bsdtar.path
            default: where_ = application(engine)?.path ?? "not installed"
            }
            return (engine, where_)
        }
    }
}
