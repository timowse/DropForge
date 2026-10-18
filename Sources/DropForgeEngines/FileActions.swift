import Foundation
import DropForgeCore

/// Copy / move / rename with the same never-overwrite rules as conversions.
public enum FileActions {
    public struct Result: Sendable {
        public var done: [URL] = []
        public var failures: [(String, String)] = []
    }

    /// Copies items into `folder`; a name clash yields "Name 2.ext" instead of replacing anything.
    public static func copy(_ items: [URL], to folder: URL) -> Result {
        var result = Result()
        let committer = OutputCommitter()
        for item in items {
            do {
                let ws = try JobWorkspace(near: folder)
                defer { ws.cleanup() }
                let staged = ws.file(item.lastPathComponent)
                try FileManager.default.copyItem(at: item, to: staged)
                let ext = item.hasDirectoryPath ? "" : item.pathExtension
                let base = ext.isEmpty ? item.lastPathComponent : OutputNaming.stem(of: item)
                result.done.append(try committer.commit(staged, into: folder, base: base, extension: ext))
            } catch {
                result.failures.append((item.lastPathComponent, UserMessage.describe(error)))
            }
        }
        return result
    }

    /// Moves items into `folder`. Same-volume moves are a single exclusive rename; otherwise copy then delete
    /// the original only after the copy is safely committed.
    public static func move(_ items: [URL], to folder: URL) -> Result {
        var result = Result()
        let committer = OutputCommitter()
        for item in items {
            if item.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                result.done.append(item)
                continue
            }
            do {
                let ext = item.hasDirectoryPath ? "" : item.pathExtension
                let base = ext.isEmpty ? item.lastPathComponent : OutputNaming.stem(of: item)
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let sameVolume = Self.volume(of: item) == Self.volume(of: folder)
                if sameVolume {
                    result.done.append(try committer.commit(item, into: folder, base: isDir ? item.lastPathComponent : base,
                                                            extension: isDir ? "" : ext))
                } else {
                    let copied = copy([item], to: folder)
                    if let url = copied.done.first {
                        try FileManager.default.removeItem(at: item)
                        result.done.append(url)
                    } else if let f = copied.failures.first {
                        result.failures.append(f)
                    }
                }
            } catch {
                result.failures.append((item.lastPathComponent, UserMessage.describe(error)))
            }
        }
        return result
    }

    static func volume(of url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// Applies a rename plan in two phases (temporary names first) so swaps like a↔b work.
    public static func rename(_ plan: [RenamePlanItem]) -> Result {
        var result = Result()
        let changing = plan.filter(\.changes)
        var temps: [(RenamePlanItem, URL)] = []
        for item in changing {
            let temp = item.source.deletingLastPathComponent().appendingPathComponent(".dropforge-rename-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: item.source, to: temp)
                temps.append((item, temp))
            } catch {
                result.failures.append((item.source.lastPathComponent, UserMessage.describe(error)))
            }
        }
        let committer = OutputCommitter()
        for (item, temp) in temps {
            let name = item.newName
            let ext = (name as NSString).pathExtension
            let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            do {
                result.done.append(try committer.commit(temp, into: item.source.deletingLastPathComponent(), base: base, extension: ext))
            } catch {
                // Put the file back under its old name rather than leave a hidden temp file.
                try? FileManager.default.moveItem(at: temp, to: item.source)
                result.failures.append((item.source.lastPathComponent, UserMessage.describe(error)))
            }
        }
        result.done += plan.filter { !$0.changes }.map(\.source)
        return result
    }
}
