import Foundation
import Darwin

public enum CommitError: Error, Equatable, LocalizedError {
    case noFreeName(String)
    case missingStagedItem(String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .noFreeName(let base): "Could not find a free file name for “\(base)”."
        case .missingStagedItem(let name): "The processed file “\(name)” was not produced."
        case .system(let op, let code): "\(op) failed: \(String(cString: strerror(code)))."
        }
    }
}

/// Moves finished files from a staging folder into place without ever replacing an existing item.
///
/// On the same volume this is one exclusive `rename` (atomic: the output appears complete or not at all).
/// Across volumes the item is first copied under a hidden temporary name inside the destination, then
/// exclusively renamed.
public struct OutputCommitter: Sendable {
    public var maxAttempts: Int

    public init(maxAttempts: Int = 9999) {
        self.maxAttempts = maxAttempts
    }

    @discardableResult
    public func commit(_ staged: URL, into directory: URL, base: String, extension ext: String) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: staged.path) else { throw CommitError.missingStagedItem(staged.lastPathComponent) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var source = staged
        var crossVolumeTemp: URL?
        defer { if let crossVolumeTemp { try? fm.removeItem(at: crossVolumeTemp) } }

        for attempt in 1...maxAttempts {
            let name = OutputNaming.candidate(base: base, extension: ext, attempt: attempt)
            let target = directory.appendingPathComponent(name)
            let result = source.withUnsafeFileSystemRepresentation { src in
                target.withUnsafeFileSystemRepresentation { dst in
                    renamex_np(src!, dst!, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                crossVolumeTemp = nil
                return target
            }
            let code = errno
            switch code {
            case EEXIST:
                continue
            case EXDEV:
                // Different volume: copy next to the destination under a hidden name, then retry the rename.
                let temp = directory.appendingPathComponent(".dropforge-\(UUID().uuidString).partial")
                do {
                    try fm.copyItem(at: source, to: temp)
                } catch {
                    try? fm.removeItem(at: temp)
                    throw CommitError.system("Copying the output", Int32(EIO))
                }
                crossVolumeTemp = temp
                source = temp
                // Re-run this attempt with the local copy.
                let retry = temp.withUnsafeFileSystemRepresentation { src in
                    target.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) }
                }
                if retry == 0 { crossVolumeTemp = nil ; return target }
                if errno != EEXIST { throw CommitError.system("Saving the output", errno) }
            case ENOTSUP, EINVAL:
                // File systems without exclusive rename (some network/FAT volumes): moveItem refuses to
                // replace an existing item, so a collision surfaces as an error instead of data loss.
                if fm.fileExists(atPath: target.path) { continue }
                do {
                    try fm.moveItem(at: source, to: target)
                    crossVolumeTemp = nil
                    return target
                } catch {
                    if fm.fileExists(atPath: target.path) { continue }
                    throw CommitError.system("Saving the output", Int32(EIO))
                }
            default:
                throw CommitError.system("Saving the output", code)
            }
        }
        throw CommitError.noFreeName(base)
    }
}

/// A private scratch folder for one unit of work. Removed by `cleanup()`, which every code path calls.
public final class JobWorkspace: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cleaned = false

    /// Creates a scratch folder, preferably on the same volume as `destination` so commits are atomic renames.
    public init(near destination: URL?) throws {
        let fm = FileManager.default
        var dir: URL?
        if let destination {
            dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        }
        if dir == nil {
            let root = fm.temporaryDirectory.appendingPathComponent("DropForge", isDirectory: true)
            let d = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            dir = d
        }
        url = dir!
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    public func subdirectory(_ name: String) throws -> URL {
        let d = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public var isCleanedUp: Bool { lock.withLock { cleaned } }

    public func cleanup() {
        lock.withLock {
            guard !cleaned else { return }
            cleaned = true
            try? FileManager.default.removeItem(at: url)
        }
    }

    deinit { cleanup() }
}
