import Foundation
import Testing
@testable import DropForgeCore

func tempDir(_ label: String = "core") throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("DropForgeTests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite("File naming and collisions")
struct NamingTests {
    @Test func stems() {
        #expect(OutputNaming.stem(of: URL(fileURLWithPath: "/a/Photo.final.jpg")) == "Photo.final")
        #expect(OutputNaming.stem(of: URL(fileURLWithPath: "/a/backup.tar.gz")) == "backup")
        #expect(OutputNaming.stem(of: URL(fileURLWithPath: "/a/README")) == "README")
        #expect(OutputNaming.stem(of: URL(fileURLWithPath: "/a/.hidden")) == ".hidden")
    }

    @Test func sanitizing() {
        #expect(OutputNaming.sanitize("a/b:c") == "a-b-c")
        #expect(OutputNaming.sanitize("  ..dots  ") == "dots")
        #expect(OutputNaming.sanitize("tab\there\u{7}") == "tabhere")
        #expect(OutputNaming.sanitize("") == "Untitled")
        #expect(OutputNaming.sanitize("Café 🎉 Ünïcode") == "Café 🎉 Ünïcode")
    }

    @Test func candidatesAreFinderStyle() {
        #expect(OutputNaming.candidate(base: "Photo", extension: "jpg", attempt: 1) == "Photo.jpg")
        #expect(OutputNaming.candidate(base: "Photo", extension: "jpg", attempt: 2) == "Photo 2.jpg")
        #expect(OutputNaming.candidate(base: "Folder", extension: "", attempt: 3) == "Folder 3")
        #expect(OutputNaming.baseName(for: URL(fileURLWithPath: "/x/Clip.mov"), suffix: "trimmed") == "Clip trimmed")
    }

    @Test func longEmojiNamesFitIn255Bytes() {
        let stem = String(repeating: "🎬é", count: 120)  // ~720 bytes
        for attempt in [1, 2, 9999] {
            let name = OutputNaming.candidate(base: stem, extension: "webm", attempt: attempt)
            #expect(name.utf8.count <= 255)
            #expect(name.hasSuffix(".webm"))
            // Truncation happens on character boundaries: the result is valid Unicode with no broken emoji.
            #expect(name.unicodeScalars.allSatisfy { $0.value != 0xFFFD })
        }
        #expect(OutputNaming.candidate(base: stem, extension: "webm", attempt: 1) != OutputNaming.candidate(base: stem, extension: "webm", attempt: 2))
    }

    @Test func previewSkipsExistingNames() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("A.png"))
        try Data().write(to: dir.appendingPathComponent("A 2.png"))
        #expect(OutputNaming.previewName(base: "A", extension: "png", in: dir) == "A 3.png")
    }

    @Test func destinationFallsBackWhenReadOnly() {
        let input = URL(fileURLWithPath: "/Volumes/ReadOnly/a.png")
        let (url, fallback) = DestinationResolver.directory(for: input, location: .besideOriginal, isWritable: { _ in false })
        #expect(fallback)
        #expect(url == DestinationResolver.fallbackDirectory)
        let (u2, f2) = DestinationResolver.directory(for: input, location: .folder(URL(fileURLWithPath: "/tmp/out")), isWritable: { _ in true })
        #expect(!f2 && u2.path == "/tmp/out")
        let (u3, _) = DestinationResolver.directory(for: input, location: .besideOriginal, isWritable: { _ in true })
        #expect(u3.path == "/Volumes/ReadOnly")
    }

    @Test func toolSuffixesAreDistinct() {
        let suffixes = ToolKind.allCases.map(OutputNaming.suffix(for:)).filter { !$0.isEmpty }
        #expect(Set(suffixes).count == suffixes.count)
    }
}

@Suite("Atomic commit")
struct CommitTests {
    @Test func commitsAndNeverOverwrites() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("Report.pdf")
        try Data("original".utf8).write(to: existing)
        let ws = try JobWorkspace(near: dir)
        defer { ws.cleanup() }
        let staged = ws.file("out.pdf")
        try Data("new".utf8).write(to: staged)
        let committed = try OutputCommitter().commit(staged, into: dir, base: "Report", extension: "pdf")
        #expect(committed.lastPathComponent == "Report 2.pdf")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "original")
        #expect(try String(contentsOf: committed, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))   // moved, not copied
    }

    @Test func commitsDirectories() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = try JobWorkspace(near: dir)
        let pages = try ws.subdirectory("pages")
        try Data("1".utf8).write(to: pages.appendingPathComponent("001.png"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Doc pages"), withIntermediateDirectories: false)
        let out = try OutputCommitter().commit(pages, into: dir, base: "Doc pages", extension: "")
        #expect(out.lastPathComponent == "Doc pages 2")
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("001.png").path))
        ws.cleanup()
    }

    @Test func missingStagedItemFails() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: CommitError.self) {
            try OutputCommitter().commit(dir.appendingPathComponent("nope"), into: dir, base: "x", extension: "txt")
        }
    }

    @Test func exhaustedNamesFail() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("A.txt"))
        try Data().write(to: dir.appendingPathComponent("A 2.txt"))
        let staged = dir.appendingPathComponent(".staged")
        try Data().write(to: staged)
        #expect(throws: CommitError.noFreeName("A")) {
            try OutputCommitter(maxAttempts: 2).commit(staged, into: dir, base: "A", extension: "txt")
        }
    }

    @Test func concurrentCommitsGetDistinctNames() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 0..<16 {
                group.addTask {
                    let ws = try JobWorkspace(near: dir)
                    defer { ws.cleanup() }
                    let f = ws.file("x")
                    try Data("\(i)".utf8).write(to: f)
                    return try OutputCommitter().commit(f, into: dir, base: "Same", extension: "txt")
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(urls.map(\.lastPathComponent)).count == 16)
    }

    @Test func workspaceIsRemovedOnCleanupAndDeinit() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var ws: JobWorkspace? = try JobWorkspace(near: dir)
        let path = ws!.url
        try Data().write(to: ws!.file("tmp"))
        #expect(FileManager.default.fileExists(atPath: path.path))
        ws = nil
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let ws2 = try JobWorkspace(near: nil)
        ws2.cleanup(); ws2.cleanup()
        #expect(ws2.isCleanedUp && !FileManager.default.fileExists(atPath: ws2.url.path))
    }

    @Test func quarantineIsInherited() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("download.png"), dst = dir.appendingPathComponent("out.jpg")
        try Data("a".utf8).write(to: src); try Data("b".utf8).write(to: dst)
        let value = "0083;00000000;Safari;"
        #expect(setxattr(src.path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        Quarantine.copy(from: src, to: dst)
        var buf = [UInt8](repeating: 0, count: 64)
        let n = getxattr(dst.path, "com.apple.quarantine", &buf, 64, 0, 0)
        #expect(n == value.utf8.count)
        // Unquarantined sources leave outputs alone.
        let plain = dir.appendingPathComponent("plain.txt"), out2 = dir.appendingPathComponent("o2.txt")
        try Data().write(to: plain); try Data().write(to: out2)
        Quarantine.copy(from: plain, to: out2)
        #expect(getxattr(out2.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
    }
}

@Suite("Process runner")
struct ProcessRunnerTests {
    let runner = SystemProcessRunner(killGrace: .milliseconds(300))

    final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    @Test func streamsLinesAndCapturesOutput() async throws {
        let lines = Lines()
        let r = try await runner.run(Command(executable: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", "printf 'a=1\\nb=2\\npartial'; echo oops >&2"])) { lines.add($0) }
        #expect(r.exitCode == 0)
        #expect(lines.all == ["a=1", "b=2", "partial"])
        #expect(r.stderr.contains("oops"))
    }

    @Test func argumentsAreNotShellInterpreted() async throws {
        let tricky = "name with spaces; $(touch /tmp/should-not-exist-dropforge) 'quotes'"
        let r = try await runner.run(Command(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [tricky]))
        #expect(r.stdoutString.trimmingCharacters(in: .newlines) == tricky)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/should-not-exist-dropforge"))
    }

    @Test func nonZeroExitBecomesReadableError() async throws {
        await #expect(throws: ProcessError.self) {
            try await runner.runChecked(Command(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'bad input file' >&2; exit 3"]))
        }
        do {
            try await runner.runChecked(Command(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'frame=1'; echo 'bad input file' >&2; exit 3"]))
        } catch let e as ProcessError {
            #expect(e == .failed(tool: "sh", code: 3, detail: "bad input file"))
        }
    }

    @Test func launchFailure() async {
        await #expect(throws: ProcessError.launchFailed("does-not-exist")) {
            try await runner.run(Command(executable: URL(fileURLWithPath: "/nonexistent/does-not-exist"), arguments: []))
        }
    }

    @Test func cancellationKillsTheChildQuickly() async throws {
        let start = Date()
        let task = Task { try await runner.run(Command(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: ProcessError.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func cancellationEscalatesToSIGKILL() async throws {
        // A child that ignores SIGTERM must still die after the grace period.
        let start = Date()
        let task = Task { try await runner.run(Command(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 4"])) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func errorTextSkipsProgressNoise() {
        let s = "frame=  10 fps=0.0\nsize=1kB\n[out#0/mp4] something\nInvalid data found when processing input\nConversion failed!\n"
        #expect(ErrorText.lastMeaningfulLine(s) == "Invalid data found when processing input")
    }
}
