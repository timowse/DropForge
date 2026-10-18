import AppKit
import ImageIO
import PDFKit
import DropForgeCore

/// Headless end-to-end check used after installation: generated fixtures → real executor → validated outputs.
public enum SmokeTest {
    public struct Case: Sendable {
        let name: String
        let input: URL
        let operation: OperationDescriptor
        let parameters: ToolParameters
        let validate: @Sendable ([URL]) throws -> Void
    }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: UnitOutcome?
        func set(_ o: UnitOutcome) { lock.withLock { outcome = o } }
        var value: UnitOutcome? { lock.withLock { outcome } }
    }

    public static func runBlocking(root: URL?) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()
        Task.detached {
            result.code = await run(root: root)
            semaphore.signal()
        }
        // Keep the main run loop alive for AppKit text/HTML work that hops to the main actor.
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return result.code
    }

    final class ResultBox: @unchecked Sendable { var code: Int32 = 1 }

    static func validImage(_ urls: [URL]) throws {
        for u in urls {
            guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetCount(s) > 0,
                  CGImageSourceCreateImageAtIndex(s, 0, nil) != nil else { throw ValidationError("\(u.lastPathComponent) is not a decodable image") }
        }
    }

    static func validNonEmpty(_ urls: [URL]) throws {
        for u in urls {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir || size > 0 else { throw ValidationError("\(u.lastPathComponent) is empty") }
        }
    }

    public static func run(root: URL?) async -> Int32 {
        let dir: URL
        do { dir = try root ?? FixtureFactory.makeTemporaryDirectory(prefix: "DropForgeSmoke") } catch { print("FAIL temp dir"); return 1 }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let locator = EngineLocator()
        let availability = locator.availability()
        print("DropForge smoke test in \(dir.path)")
        for (e, where_) in locator.report() { print("  engine \(e.displayName): \(where_)") }
        let f = FixtureFactory(directory: dir, locator: locator)
        let ffprobe = locator.ffprobe
        let probeOK: @Sendable ([URL]) throws -> Void = { urls in
            guard let ffprobe else { throw ValidationError("ffprobe missing") }
            for u in urls {
                let p = Process()
                p.executableURL = ffprobe
                p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", u.path]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
                try p.run(); p.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                guard p.terminationStatus == 0, (Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 else {
                    throw ValidationError("ffprobe rejected \(u.lastPathComponent)")
                }
            }
        }
        _ = probeOK
        var cases: [Case] = []
        func convert(_ name: String, _ input: URL, _ format: FileFormat, _ validate: @escaping @Sendable ([URL]) throws -> Void) {
            let source = FileFormat.detect(input)
            cases.append(Case(name: name, input: input, operation: Catalog.conversionDescriptor(.format(format), source: source, combined: false),
                              parameters: .none, validate: validate))
        }
        do {
            let png = try await f.image("card.png", format: .png, alpha: true)
            let jpg = try await f.image("photo.jpg", format: .jpeg, withMetadata: true)
            let svg = try f.svg("vector.svg")
            let pdf = try f.pdf("doc.pdf", pages: 2)
            let md = try f.text("notes.md", FixtureFactory.sampleMarkdown)
            let csv = try f.text("table.csv", "name,value\n\"a, b\",1\nc,2\n")
            let srt = try f.text("subs.srt", FixtureFactory.sampleSRT)
            let qr = try f.qrCode("code.png", payload: "https://dropforge.local/smoke")
            convert("PNG → JPG", png, .jpeg, validImage)
            convert("PNG → HEIC", png, .heic, validImage)
            convert("PNG → AVIF", png, .avif, validImage)
            convert("JPG → WebP", jpg, .webp, validImage)
            convert("SVG → PNG", svg, .png, validImage)
            convert("PDF → PNG pages", pdf, .png, { urls in
                let files = try FileManager.default.contentsOfDirectory(at: urls[0], includingPropertiesForKeys: nil)
                guard files.count == 2 else { throw ValidationError("expected 2 pages, got \(files.count)") }
                try validImage(files)
            })
            convert("PDF → TXT", pdf, .txt, { urls in
                guard try String(contentsOf: urls[0], encoding: .utf8).contains("page 2") else { throw ValidationError("text missing") }
            })
            convert("Markdown → DOCX", md, .docx, validNonEmpty)
            convert("Markdown → EPUB", md, .epub, validNonEmpty)
            convert("Markdown → PDF", md, .pdf, { urls in
                guard PDFDocument(url: urls[0])?.string?.contains("DropForge fixture") == true else { throw ValidationError("PDF text missing") }
            })
            convert("CSV → TSV", csv, .tsv, { urls in
                guard try String(contentsOf: urls[0], encoding: .utf8).contains("a, b\t1") else { throw ValidationError("TSV wrong") }
            })
            convert("SRT → VTT", srt, .vtt, { urls in
                guard try String(contentsOf: urls[0], encoding: .utf8).hasPrefix("WEBVTT") else { throw ValidationError("VTT header missing") }
            })
            cases.append(Case(name: "Image compress to 30 KB", input: jpg, operation: Catalog.tool(.compress),
                              parameters: .compress(CompressOptions(mode: .targetBytes(30_000))), validate: { urls in
                                  try validImage(urls)
                                  let size = (try urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                                  guard size <= 30_000 else { throw ValidationError("too large: \(size)") }
                              }))
            cases.append(Case(name: "Read QR", input: qr, operation: Catalog.tool(.readQR), parameters: .none, validate: { urls in
                guard try String(contentsOf: urls[0], encoding: .utf8).contains("dropforge.local/smoke") else { throw ValidationError("QR payload missing") }
            }))
            if availability.contains(.ffmpeg) {
                let mp4 = try await f.video("clip.mp4", seconds: 1.5)
                let wav = try await f.audio("tone.wav", seconds: 1.5)
                convert("MP4 → WebM", mp4, .webm, probeOK)
                convert("MP4 → MP3", mp4, .mp3, probeOK)
                convert("MP4 → GIF", mp4, .gif, validImage)
                convert("WAV → FLAC", wav, .flac, probeOK)
                convert("WAV → OGG", wav, .ogg, probeOK)
                convert("WAV → Opus", wav, .opus, probeOK)
            } else {
                print("SKIP media cases: ffmpeg not found")
            }
            if availability.contains(.libreOffice) {
                let docx = try f.richDocument("letter.docx", type: .officeOpenXML)
                convert("DOCX → PDF (LibreOffice)", docx, .pdf, { urls in
                    guard PDFDocument(url: urls[0]) != nil else { throw ValidationError("not a PDF") }
                })
                convert("CSV → XLSX (LibreOffice)", csv, .xlsx, validNonEmpty)
            } else {
                print("SKIP office cases: LibreOffice not installed")
            }
            let folder = dir.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: folder.appendingPathComponent("a.txt"))
            cases.append(Case(name: "Folder → ZIP", input: folder, operation: Catalog.conversionDescriptor(.format(.zip), source: nil, combined: false),
                              parameters: .none, validate: validNonEmpty))
            let zip = try await f.archive("bundle.zip", format: .zip, containing: [md, csv])
            cases.append(Case(name: "ZIP → extract", input: zip, operation: Catalog.conversionDescriptor(.extract, source: .zip, combined: false),
                              parameters: .none, validate: { urls in
                                  let names = try FileManager.default.contentsOfDirectory(atPath: urls[0].path)
                                  guard Set(names).isSuperset(of: ["notes.md", "table.csv"]) else { throw ValidationError("entries missing: \(names)") }
                              }))
        } catch {
            print("FAIL fixture generation: \(UserMessage.describe(error))")
            return 1
        }

        let resolver = CapabilityResolver(availability: availability)
        let executor = JobExecutor(performer: DefaultPerformer(locator: locator), resolver: resolver, location: .besideOriginal)
        var failures = 0
        var lines: [String] = []
        for c in cases {
            let selection = Selection(urls: [c.input])
            let plan = JobPlanner.plan(c.operation, selection: selection, parameters: c.parameters)
            let collector = Collector()
            let start = Date()
            await executor.run(plan) { event in
                if case .unitFinished(_, let o) = event { collector.set(o) }
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            switch collector.value {
            case .succeeded(let urls, _):
                do {
                    try c.validate(urls)
                    lines.append("PASS \(c.name) (\(ms) ms) → \(urls.map(\.lastPathComponent).joined(separator: ", "))")
                } catch {
                    failures += 1
                    lines.append("FAIL \(c.name): output invalid: \(UserMessage.describe(error))")
                }
            case .some(let other):
                failures += 1
                lines.append("FAIL \(c.name): \(other)")
            case .none:
                failures += 1
                lines.append("FAIL \(c.name): no result")
            }
        }
        lines.forEach { print($0) }
        print("SUMMARY \(cases.count - failures)/\(cases.count) passed")
        try? (lines.joined(separator: "\n") + "\nSUMMARY \(cases.count - failures)/\(cases.count) passed\n")
            .write(to: dir.appendingPathComponent("smoke-report.txt"), atomically: true, encoding: .utf8)
        return failures == 0 ? 0 : 2
    }
}
