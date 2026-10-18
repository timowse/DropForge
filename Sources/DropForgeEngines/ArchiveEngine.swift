import Foundation
import DropForgeCore

public enum ArchiveError: Error, LocalizedError, Equatable {
    case unsafeEntries([String])
    case empty(String)
    public var errorDescription: String? {
        switch self {
        case .unsafeEntries(let e): "The archive contains unsafe paths (\(e.prefix(3).joined(separator: ", "))), so it was not extracted."
        case .empty(let n): "“\(n)” is empty."
        }
    }
}

public struct ArchiveEngine: Sendable {
    public let runner: ProcessRunning

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    public func create(_ format: FileFormat, items: [URL], output: URL) async throws {
        try await runner.runChecked(Command(executable: ArchiveCommands.bsdtar,
                                            arguments: ArchiveCommands.create(format, items: items, output: output)))
    }

    /// Extracts into a new folder inside the workspace and returns what should be committed:
    /// the single top-level item, or the folder holding several.
    public func extract(_ archive: URL, workspace: JobWorkspace) async throws -> (url: URL, isFolder: Bool) {
        let dir = try workspace.subdirectory("extracted")
        if ArchiveCommands.isPlainGzip(archive) {
            let staged = dir.appendingPathComponent(archive.lastPathComponent)
            try FileManager.default.copyItem(at: archive, to: staged)
            try await runner.runChecked(Command(executable: ArchiveCommands.gzip, arguments: ArchiveCommands.gunzipInPlace(staged)))
            try FileManager.default.removeItem(at: staged)
        } else {
            let listing = try await runner.runChecked(Command(executable: ArchiveCommands.bsdtar, arguments: ArchiveCommands.list(archive)))
            let unsafe = ArchiveCommands.unsafeEntries(in: listing.stdoutString)
            guard unsafe.isEmpty else { throw ArchiveError.unsafeEntries(unsafe) }
            try await runner.runChecked(Command(executable: ArchiveCommands.bsdtar, arguments: ArchiveCommands.extract(archive, into: dir)))
        }
        let top = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        guard !top.isEmpty else { throw ArchiveError.empty(archive.lastPathComponent) }
        if top.count == 1 { return (top[0], false) }
        return (dir, true)
    }
}
