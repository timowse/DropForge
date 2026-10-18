import Foundation

/// Argument builders for the system archive tools (`/usr/bin/bsdtar`, libarchive; `/usr/bin/gzip`).
/// bsdtar refuses absolute paths and `..` components on extraction unless `-P` is given; DropForge never passes `-P`.
public enum ArchiveCommands {
    public static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    public static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")

    static let excludes = ["--exclude", ".DS_Store", "--exclude", "__MACOSX"]

    /// Creates an archive of `items` (each added by its own name, relative to its own folder).
    public static func create(_ format: FileFormat, items: [URL], output: URL) -> [String] {
        var args: [String] = ["-c", "--no-mac-metadata"] + excludes
        switch format {
        case .zip: args += ["--format", "zip"]
        case .tar: args += ["--format", "pax"]
        case .tgz, .gz: args += ["--format", "pax", "-z"]
        default: break
        }
        args += ["-f", output.path]
        for item in items {
            args += ["-C", item.deletingLastPathComponent().path, item.lastPathComponent]
        }
        return args
    }

    public static func extract(_ archive: URL, into directory: URL) -> [String] {
        ["-x", "--no-same-owner", "-f", archive.path, "-C", directory.path]
    }

    public static func list(_ archive: URL) -> [String] {
        ["-t", "-f", archive.path]
    }

    /// `gzip -d -k file.gz` (decompresses next to the file; used on a staged copy).
    public static func gunzipInPlace(_ file: URL) -> [String] {
        ["-d", "-k", "-f", file.path]
    }

    /// True when a `.gz` is a plain gzip stream rather than a tarball (decided by name).
    public static func isPlainGzip(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return (name.hasSuffix(".gz") || name.hasSuffix(".gzip")) && !name.hasSuffix(".tar.gz")
    }

    /// Rejects archive listings with entries that would escape the destination (defence in depth).
    public static func unsafeEntries(in listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).map(String.init).filter { entry in
            entry.hasPrefix("/") || entry.split(separator: "/").contains("..")
        }
    }
}
