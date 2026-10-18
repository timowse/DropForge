import Foundation
import DropForgeCore

public enum MediaError: Error, LocalizedError, Equatable {
    case missingFFmpeg
    case unreadable(String)
    case noAudio(String)
    case noVideo(String)

    public var errorDescription: String? {
        switch self {
        case .missingFFmpeg: "The FFmpeg helper is missing. Reinstall DropForge."
        case .unreadable(let n): "“\(n)” could not be read as audio or video."
        case .noAudio(let n): "“\(n)” has no audio track."
        case .noVideo(let n): "“\(n)” has no video track."
        }
    }
}

/// Runs ffmpeg/ffprobe. All argument lists come from `FFmpegCommands`, so tests can check them with a fake runner.
public struct MediaEngine: Sendable {
    public let runner: ProcessRunning
    public let locator: EngineLocator

    public init(runner: ProcessRunning = SystemProcessRunner(), locator: EngineLocator = EngineLocator()) {
        self.runner = runner
        self.locator = locator
    }

    func tools() throws -> (ffmpeg: URL, ffprobe: URL) {
        guard let f = locator.ffmpeg, let p = locator.ffprobe else { throw MediaError.missingFFmpeg }
        return (f, p)
    }

    public func probe(_ url: URL) async throws -> MediaInfo {
        let (_, ffprobe) = try tools()
        let result = try await runner.run(Command(executable: ffprobe, arguments: FFprobeParser.arguments(for: url)))
        guard result.exitCode == 0, let info = try? FFprobeParser.parse(result.stdout), info.hasAudio || info.hasVideo else {
            throw MediaError.unreadable(url.lastPathComponent)
        }
        return info
    }

    /// Runs ffmpeg and maps its progress output onto `progress` (scaled into `range`).
    public func ffmpeg(_ arguments: [String], duration: Double?, range: ClosedRange<Double> = 0...1,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let (ffmpeg, _) = try tools()
        let parser = LockedParser(FFmpegProgressParser(totalDuration: duration))
        try await runner.runChecked(Command(executable: ffmpeg, arguments: arguments)) { line in
            if let f = parser.consume(line) {
                progress(range.lowerBound + f * (range.upperBound - range.lowerBound))
            }
        }
        progress(range.upperBound)
    }

    // MARK: Operations (each writes exactly the given output path)

    public func convert(_ input: URL, to format: FileFormat, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await probe(input)
        if format.kind == .audio && !info.hasAudio { throw MediaError.noAudio(input.lastPathComponent) }
        if (format.kind == .video || format == .gif) && !info.hasVideo { throw MediaError.noVideo(input.lastPathComponent) }
        try await ffmpeg(FFmpegCommands.convert(input: input, output: output, to: format, info: info),
                         duration: info.duration, progress: progress)
    }

    public func compress(_ input: URL, kind: FileKind, format: FileFormat, options: CompressOptions, inputBytes: Int64,
                         output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await probe(input)
        let args: [String]
        if kind == .video {
            args = try FFmpegCommands.compressVideo(input: input, output: output, format: format, options: options,
                                                    info: info, inputBytes: inputBytes)
        } else {
            args = try FFmpegCommands.compressAudio(input: input, output: output, format: format, options: options,
                                                    info: info, inputBytes: inputBytes)
        }
        try await ffmpeg(args, duration: info.duration, progress: progress)
    }

    public func trim(_ input: URL, format: FileFormat, span: TimeSpan, output: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await probe(input)
        try InputParsing.validate(span, duration: info.duration)
        let end = min(span.end, info.duration ?? span.end)
        let clipped = TimeSpan(start: span.start, end: end)
        try await ffmpeg(FFmpegCommands.trim(input: input, output: output, format: format, span: clipped, info: info),
                         duration: clipped.duration, progress: progress)
    }

    public func crop(_ input: URL, format: FileFormat, rect: UnitRect, output: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await probe(input)
        guard info.hasVideo else { throw MediaError.noVideo(input.lastPathComponent) }
        try await ffmpeg(FFmpegCommands.cropVideo(input: input, output: output, format: format, rect: rect, info: info),
                         duration: info.duration, progress: progress)
    }

    public func speed(_ input: URL, format: FileFormat, factor: Double, output: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await probe(input)
        try await ffmpeg(FFmpegCommands.speed(input: input, output: output, format: format, factor: factor, info: info),
                         duration: info.duration.map { $0 / factor }, progress: progress)
    }

    /// Writes parts as `<directory>/<n>.<ext>` and returns them in order.
    public func split(_ input: URL, format: FileFormat, mode: SplitOptions.Mode, directory: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let info = try await probe(input)
        guard let duration = info.duration else { throw FFmpegCommands.CompressError.unknownDuration }
        let spans = FFmpegCommands.splitSpans(mode, duration: duration)
        guard spans.count >= 2 else { throw ValidationError("These split points make only one part.") }
        var outputs: [URL] = []
        for (i, span) in spans.enumerated() {
            try Task.checkCancellation()
            let out = directory.appendingPathComponent("\(i + 1).\(format.preferredExtension)")
            let lo = Double(i) / Double(spans.count), hi = Double(i + 1) / Double(spans.count)
            try await ffmpeg(FFmpegCommands.trim(input: input, output: out, format: format, span: span, info: info),
                             duration: span.duration, range: lo...hi, progress: progress)
            outputs.append(out)
        }
        return outputs
    }

    public func snapshots(_ input: URL, options: SnapshotOptions, directory: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let info = try await probe(input)
        guard info.hasVideo else { throw MediaError.noVideo(input.lastPathComponent) }
        let times = FFmpegCommands.snapshotTimes(options.mode, duration: info.duration ?? 0)
        guard !times.isEmpty else { throw ValidationError("No snapshot times fall inside the video.") }
        var outputs: [URL] = []
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            let out = directory.appendingPathComponent(String(format: "%03d.%@", i + 1, options.format.preferredExtension))
            try await ffmpeg(FFmpegCommands.snapshot(input: input, output: out, at: t), duration: nil, progress: { _ in })
            outputs.append(out)
            progress(Double(i + 1) / Double(times.count))
        }
        return outputs
    }

    public func join(_ inputs: [URL], format: FileFormat, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var infos: [MediaInfo] = []
        for url in inputs { infos.append(try await probe(url)) }
        if format.kind == .video, let bad = zip(inputs, infos).first(where: { !$0.1.hasVideo }) {
            throw MediaError.noVideo(bad.0.lastPathComponent)
        }
        let total = infos.compactMap(\.duration).reduce(0, +)
        try await ffmpeg(FFmpegCommands.join(inputs: inputs, output: output, format: format, infos: infos),
                         duration: total, progress: progress)
    }

    public func run(_ build: (MediaInfo) throws -> [String], input: URL, requireAudio: Bool = false,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await probe(input)
        if requireAudio && !info.hasAudio { throw MediaError.noAudio(input.lastPathComponent) }
        try await ffmpeg(try build(info), duration: info.duration, progress: progress)
    }

    /// Display rows for the metadata viewer.
    public func metadataRows(_ url: URL) async -> [(String, String, String)] {
        guard let info = try? await probe(url) else { return [] }
        var rows: [(String, String, String)] = []
        if let d = info.duration { rows.append(("Format", "Duration", InputParsing.formatTime(d))) }
        if let f = info.formatName { rows.append(("Format", "Container", f)) }
        if let b = info.bitRate { rows.append(("Format", "Bit rate", "\(b / 1000) kb/s")) }
        if let v = info.videoCodec {
            rows.append(("Video", "Codec", v))
            if let w = info.width, let h = info.height { rows.append(("Video", "Size", "\(w) × \(h)")) }
            if let r = info.frameRate { rows.append(("Video", "Frame rate", String(format: "%.2f fps", r))) }
        }
        if let a = info.audioCodec {
            rows.append(("Audio", "Codec", a))
            if let c = info.audioChannels { rows.append(("Audio", "Channels", "\(c)")) }
            if let s = info.sampleRate { rows.append(("Audio", "Sample rate", "\(s) Hz")) }
        }
        for (k, v) in info.tags.sorted(by: { $0.key < $1.key }) { rows.append(("Tags", k, v)) }
        return rows
    }
}

/// Lets the line callback (called on a pipe thread) update parser state safely.
final class LockedParser: @unchecked Sendable {
    private var parser: FFmpegProgressParser
    private let lock = NSLock()
    init(_ parser: FFmpegProgressParser) { self.parser = parser }
    func consume(_ line: String) -> Double? { lock.withLock { parser.consume(line) } }
}
