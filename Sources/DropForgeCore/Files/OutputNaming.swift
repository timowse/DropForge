import Foundation

/// Builds output file names. Never decides on overwriting; `OutputCommitter` claims names exclusively.
public enum OutputNaming {
    /// Maximum file name length in UTF-8 bytes on APFS/HFS+.
    public static let maxNameBytes = 255
    /// Room kept for a collision counter such as " 9999".
    static let counterReserve = 6

    /// The input's name without its extension (handles `.tar.gz`).
    public static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for double in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(double) && name.count > double.count {
            return String(name.dropLast(double.count))
        }
        let ext = url.pathExtension
        if ext.isEmpty || ext.count == name.count - 1 { return name }
        return String(name.dropLast(ext.count + 1))
    }

    /// Removes characters macOS file names cannot hold and trims what Finder would hide.
    public static func sanitize(_ raw: String) -> String {
        var s = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Untitled" : s
    }

    /// Truncates `stem` (on character boundaries) so that `stem + counter + ext` fits in 255 bytes.
    public static func fit(stem: String, extension ext: String) -> String {
        let extBytes = ext.isEmpty ? 0 : ext.utf8.count + 1
        let budget = maxNameBytes - extBytes - counterReserve
        guard stem.utf8.count > budget else { return stem }
        var out = ""
        for ch in stem {
            if out.utf8.count + String(ch).utf8.count > budget - 1 { break }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Base name for an output: input stem plus an optional suffix such as "compressed".
    public static func baseName(for input: URL, suffix: String? = nil) -> String {
        let stem = sanitize(stem(of: input))
        guard let suffix, !suffix.isEmpty else { return stem }
        return "\(stem) \(suffix)"
    }

    /// The n-th candidate (n = 1 is the plain name), Finder style: "Name.ext", "Name 2.ext", "Name 3.ext".
    public static func candidate(base: String, extension ext: String, attempt n: Int) -> String {
        let fitted = fit(stem: sanitize(base), extension: ext)
        let stem = n <= 1 ? fitted : "\(fitted) \(n)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// First free name in `directory` (non-atomic check; use only for previews).
    public static func previewName(base: String, extension ext: String, in directory: URL,
                                   fileManager: FileManager = .default) -> String {
        for n in 1...9999 {
            let name = candidate(base: base, extension: ext, attempt: n)
            if !fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) { return name }
        }
        return candidate(base: base, extension: ext, attempt: 10000)
    }

    /// Suffix used by each tool in output names.
    public static func suffix(for tool: ToolKind) -> String {
        switch tool {
        case .compress: "compressed"
        case .resize: "resized"
        case .crop: "cropped"
        case .rotate: "rotated"
        case .adjust: "adjusted"
        case .annotate: "annotated"
        case .frame: "framed"
        case .redact: "redacted"
        case .metadata: "edited"
        case .stripMetadata: "clean"
        case .trim: "trimmed"
        case .speed: "speed"
        case .split: "part"
        case .join: "joined"
        case .snapshot: "frame"
        case .mute: "muted"
        case .normalize: "normalized"
        case .channels: "channels"
        case .bleep: "bleeped"
        case .merge: "merged"
        case .organize: "reordered"
        case .imagesToPDF: ""
        case .collage: "collage"
        case .readQR: "QR codes"
        case .rename: ""
        case .archive: ""
        }
    }
}

/// Where outputs go.
public enum OutputLocation: Sendable, Hashable, Codable {
    case besideOriginal
    case folder(URL)
}

public enum DestinationResolver {
    /// Fallback when the original's folder is not writable.
    public static var fallbackDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("DropForge", isDirectory: true)
    }

    /// Destination directory for outputs derived from `input`, plus whether a fallback was used.
    public static func directory(for input: URL, location: OutputLocation,
                                 isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) })
        -> (url: URL, usedFallback: Bool) {
        let preferred: URL
        switch location {
        case .besideOriginal: preferred = input.deletingLastPathComponent()
        case .folder(let url): preferred = url
        }
        if isWritable(preferred) { return (preferred, false) }
        return (fallbackDirectory, true)
    }
}
