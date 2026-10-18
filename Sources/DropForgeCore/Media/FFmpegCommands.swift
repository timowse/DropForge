import Foundation

/// Builds ffmpeg argument lists. Pure functions: tests check them without running anything.
///
/// Every command:
/// - never overwrites (`-n`) — outputs are written into a fresh staging folder anyway;
/// - reports machine-readable progress on stdout (`-progress pipe:1 -nostats`);
/// - keeps source metadata (`-map_metadata 0`) unless the tool removes it.
public enum FFmpegCommands {
    static let prefix = ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]

    // MARK: Codec choices

    /// Video codecs that MP4/MOV can carry as-is.
    static let mp4VideoCopyable: Set<String> = ["h264", "hevc"]
    static let mp4AudioCopyable: Set<String> = ["aac", "mp3", "alac"]
    static let mkvVideoCopyable: Set<String> = ["h264", "hevc", "vp9", "vp8", "av1", "mpeg4"]
    static let mkvAudioCopyable: Set<String> = ["aac", "mp3", "opus", "vorbis", "flac", "ac3", "eac3", "alac", "pcm_s16le"]

    public struct VideoQuality: Sendable, Hashable {
        public var crf: Int
        public var x264Preset: String
        public var audioBitrate: Int
        public init(crf: Int, x264Preset: String = "medium", audioBitrate: Int = 160_000) {
            self.crf = crf; self.x264Preset = x264Preset; self.audioBitrate = audioBitrate
        }
        public static let standard = VideoQuality(crf: 20)
    }

    /// Encoder arguments for a target container. `info` enables lossless stream copy when possible.
    static func encoderArguments(for format: FileFormat, info: MediaInfo?, quality: VideoQuality = .standard,
                                 allowCopy: Bool = true) -> [String] {
        let v = info?.videoCodec, a = info?.audioCodec
        let hasAudio = info?.hasAudio ?? true
        let audioArgs: (String) -> [String] = { codec in hasAudio ? codec.split(separator: " ").map(String.init) : ["-an"] }
        switch format {
        case .mp4, .mov, .m4v:
            var args: [String] = []
            if allowCopy, let v, mp4VideoCopyable.contains(v) {
                args += ["-c:v", "copy"]
                if v == "hevc" { args += ["-tag:v", "hvc1"] }
            } else {
                args += ["-c:v", "libx264", "-preset", quality.x264Preset, "-crf", String(quality.crf), "-pix_fmt", "yuv420p"]
            }
            if allowCopy, let a, mp4AudioCopyable.contains(a) {
                args += audioArgs("-c:a copy")
            } else {
                args += audioArgs("-c:a aac -b:a \(quality.audioBitrate)")
            }
            if format != .mov { args += ["-movflags", "+faststart"] }
            return args
        case .mkv:
            var args: [String] = []
            if allowCopy, let v, mkvVideoCopyable.contains(v) { args += ["-c:v", "copy"] }
            else { args += ["-c:v", "libx264", "-preset", quality.x264Preset, "-crf", String(quality.crf), "-pix_fmt", "yuv420p"] }
            if allowCopy, let a, mkvAudioCopyable.contains(a) { args += audioArgs("-c:a copy") }
            else { args += audioArgs("-c:a aac -b:a \(quality.audioBitrate)") }
            return args
        case .webm:
            let crf = min(63, quality.crf + 12)
            return ["-c:v", "libvpx-vp9", "-crf", String(crf), "-b:v", "0", "-row-mt", "1", "-deadline", "good",
                    "-cpu-used", "4", "-pix_fmt", "yuv420p"] + audioArgs("-c:a libopus -b:a 128000")
        case .mp3: return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a, .aac: return ["-vn", "-c:a", "aac", "-b:a", "192000", "-movflags", "+faststart"]
        case .wav: return ["-vn", "-c:a", "pcm_s16le"]
        case .aiff: return ["-vn", "-c:a", "pcm_s16be"]
        case .flac: return ["-vn", "-c:a", "flac"]
        // FFmpeg's built-in Vorbis encoder is stereo only.
        case .ogg: return ["-vn", "-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-q:a", "5"]
        case .opus: return ["-vn", "-c:a", "libopus", "-b:a", "128000"]
        default: return []
        }
    }

    /// Palette-based GIF with a sane size cap.
    static func gifFilter(maxWidth: Int = 720, fps: Int = 12) -> String {
        "fps=\(fps),scale='min(\(maxWidth),iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"
    }

    // MARK: Conversion

    public static func convert(input: URL, output: URL, to format: FileFormat, info: MediaInfo?) -> [String] {
        var args = prefix + ["-i", input.path, "-map_metadata", "0"]
        if format == .gif {
            args += ["-filter_complex", gifFilter(), "-loop", "0", "-an"]
        } else if format.kind == .audio {
            args += ["-map", "0:a:0"] + encoderArguments(for: format, info: info)
        } else if info?.formatName == "gif" || input.pathExtension.lowercased() == "gif" {
            // Animated GIF → video: even dimensions are required by yuv420p encoders.
            args += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
                + encoderArguments(for: format, info: MediaInfo(videoCodec: "gif"), allowCopy: false)
        } else {
            args += ["-map", "0:v:0?", "-map", "0:a:0?"] + encoderArguments(for: format, info: info)
        }
        return args + [output.path]
    }

    // MARK: Compression

    /// Audio bitrate (bits/s) for presets.
    public static func audioBitrate(for preset: CompressOptions.Preset) -> Int {
        switch preset {
        case .high: 192_000
        case .balanced: 128_000
        case .small: 64_000
        }
    }

    public static func crf(for preset: CompressOptions.Preset) -> Int {
        switch preset {
        case .high: 23
        case .balanced: 28
        case .small: 33
        }
    }

    /// Video bitrate that makes the file land near `targetBytes`, leaving room for audio and container overhead.
    public static func videoBitrate(targetBytes: Int64, duration: Double, audioBitrate: Int) -> Int? {
        guard duration > 0, targetBytes > 0 else { return nil }
        let totalBits = Double(targetBytes) * 8 * 0.96   // ~4 % container overhead
        let video = totalBits / duration - Double(audioBitrate)
        guard video >= 50_000 else { return nil }          // below this the result would be unwatchable
        return Int(video)
    }

    /// Target size implied by a compress mode, in bytes.
    public static func targetBytes(for mode: CompressOptions.Mode, inputBytes: Int64) -> Int64? {
        switch mode {
        case .preset: nil
        case .percent(let p): Int64(Double(inputBytes) * Double(min(max(p, 1), 99)) / 100)
        case .targetBytes(let b): b
        }
    }

    static func scaleFilter(maxDimension: Int) -> String {
        "scale='if(gte(iw,ih),min(iw,\(maxDimension)),-2)':'if(gte(iw,ih),-2,min(ih,\(maxDimension)))'"
    }

    /// Output container for compressing a video of `format`.
    public static func compressedVideoFormat(for format: FileFormat) -> FileFormat {
        switch format {
        case .webm: .webm
        case .mkv: .mkv
        case .mov: .mov
        default: .mp4
        }
    }

    public enum CompressError: Error, Equatable, LocalizedError {
        case targetTooSmall
        case unknownDuration
        public var errorDescription: String? {
            switch self {
            case .targetTooSmall: "The target size is too small for this length. Choose a larger size."
            case .unknownDuration: "The length of this file could not be read, so a target size cannot be used."
            }
        }
    }

    public static func compressVideo(input: URL, output: URL, format: FileFormat, options: CompressOptions,
                                     info: MediaInfo, inputBytes: Int64) throws -> [String] {
        var args = prefix + ["-i", input.path, "-map_metadata", "0", "-map", "0:v:0", "-map", "0:a:0?"]
        if let max = options.maxDimension { args += ["-vf", scaleFilter(maxDimension: max)] }
        let audioBR: Int
        switch options.mode {
        case .preset(let p): audioBR = p == .small ? 96_000 : 128_000
        default: audioBR = 96_000
        }
        let isWebM = format == .webm
        if let target = targetBytes(for: options.mode, inputBytes: inputBytes) {
            guard let duration = info.duration else { throw CompressError.unknownDuration }
            guard let vbr = videoBitrate(targetBytes: target, duration: duration, audioBitrate: info.hasAudio ? audioBR : 0)
            else { throw CompressError.targetTooSmall }
            if isWebM {
                args += ["-c:v", "libvpx-vp9", "-b:v", String(vbr), "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            } else {
                args += ["-c:v", "libx264", "-preset", "medium", "-b:v", String(vbr), "-maxrate", String(Int(Double(vbr) * 1.5)),
                         "-bufsize", String(vbr * 2)]
            }
        } else if case .preset(let p) = options.mode {
            if isWebM {
                args += ["-c:v", "libvpx-vp9", "-crf", String(crf(for: p) + 8), "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            } else {
                args += ["-c:v", "libx264", "-preset", "medium", "-crf", String(crf(for: p))]
            }
        }
        args += ["-pix_fmt", "yuv420p"]
        if info.hasAudio {
            args += isWebM ? ["-c:a", "libopus", "-b:a", String(audioBR)] : ["-c:a", "aac", "-b:a", String(audioBR)]
        }
        if format == .mp4 { args += ["-movflags", "+faststart"] }
        return args + [output.path]
    }

    /// Lossy audio formats keep their format when compressed; lossless ones become AAC (M4A).
    public static func compressedAudioFormat(for format: FileFormat) -> FileFormat {
        switch format {
        case .mp3, .ogg, .opus, .m4a: format
        default: .m4a
        }
    }

    public static func compressAudio(input: URL, output: URL, format: FileFormat, options: CompressOptions,
                                     info: MediaInfo, inputBytes: Int64) throws -> [String] {
        var bitrate: Int
        if let target = targetBytes(for: options.mode, inputBytes: inputBytes) {
            guard let d = info.duration, d > 0 else { throw CompressError.unknownDuration }
            bitrate = Int(Double(target) * 8 * 0.97 / d)
            guard bitrate >= 24_000 else { throw CompressError.targetTooSmall }
            bitrate = min(bitrate, 320_000)
        } else if case .preset(let p) = options.mode {
            bitrate = audioBitrate(for: p)
        } else {
            bitrate = 128_000
        }
        var args = prefix + ["-i", input.path, "-map_metadata", "0", "-map", "0:a:0", "-vn"]
        switch format {
        case .mp3: args += ["-c:a", "libmp3lame", "-b:a", String(bitrate)]
        case .ogg: args += ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-b:a", String(max(bitrate, 64_000))]
        case .opus: args += ["-c:a", "libopus", "-b:a", String(bitrate)]
        default: args += ["-c:a", "aac", "-b:a", String(bitrate), "-movflags", "+faststart"]
        }
        return args + [output.path]
    }

    // MARK: Editing tools

    /// Re-encoding arguments for edits (filters invalidate stream copy).
    static func reencode(_ format: FileFormat, info: MediaInfo) -> [String] {
        encoderArguments(for: format, info: info, allowCopy: false)
    }

    public static func trim(input: URL, output: URL, format: FileFormat, span: TimeSpan, info: MediaInfo) -> [String] {
        prefix + ["-ss", seconds(span.start), "-i", input.path, "-t", seconds(span.duration), "-map_metadata", "0",
                  "-map", "0:v:0?", "-map", "0:a:0?"] + reencode(format, info: info) + [output.path]
    }

    /// Crops video using ffmpeg expressions, keeping dimensions even for yuv420p.
    public static func cropVideo(input: URL, output: URL, format: FileFormat, rect: UnitRect, info: MediaInfo) -> [String] {
        let f = { (v: Double) in String(format: "%.6f", v) }
        let filter = "crop=trunc(iw*\(f(rect.width))/2)*2:trunc(ih*\(f(rect.height))/2)*2:trunc(iw*\(f(rect.x))):trunc(ih*\(f(rect.y)))"
        return prefix + ["-i", input.path, "-map_metadata", "0", "-map", "0:v:0", "-map", "0:a:0?", "-vf", filter]
            + reencode(format, info: info).filter { $0 != "-vn" } + [output.path]
    }

    /// atempo accepts 0.5...2.0 per instance on older builds; chain instances for other factors.
    public static func atempoChain(_ factor: Double) -> String {
        var remaining = factor
        var parts: [String] = []
        while remaining > 2.0 { parts.append("atempo=2.0"); remaining /= 2.0 }
        while remaining < 0.5 { parts.append("atempo=0.5"); remaining /= 0.5 }
        parts.append("atempo=\(String(format: "%.6g", remaining))")
        return parts.joined(separator: ",")
    }

    public static func speed(input: URL, output: URL, format: FileFormat, factor: Double, info: MediaInfo) -> [String] {
        var args = prefix + ["-i", input.path, "-map_metadata", "0"]
        if info.hasVideo && format.kind == .video {
            args += ["-map", "0:v:0", "-filter:v", "setpts=PTS/\(String(format: "%.6g", factor))"]
            if info.hasAudio { args += ["-map", "0:a:0", "-filter:a", atempoChain(factor)] }
        } else {
            args += ["-map", "0:a:0", "-filter:a", atempoChain(factor)]
        }
        return args + reencode(format, info: info) + [output.path]
    }

    /// Spans for a split, clipped to the duration. Throws when the request makes no parts.
    public static func splitSpans(_ mode: SplitOptions.Mode, duration: Double) -> [TimeSpan] {
        guard duration > 0 else { return [] }
        var cuts: [Double]
        switch mode {
        case .atTimes(let times):
            cuts = Array(Set(times.filter { $0 > 0.05 && $0 < duration - 0.05 })).sorted()
        case .equalParts(let n):
            let n = max(1, n)
            cuts = (1..<n).map { Double($0) * duration / Double(n) }
        case .every(let length):
            guard length > 0.1 else { return [] }
            cuts = Array(stride(from: length, to: duration - 0.05, by: length))
        }
        let edges = [0] + cuts + [duration]
        return zip(edges, edges.dropFirst()).map { TimeSpan(start: $0, end: $1) }
    }

    public static func snapshotTimes(_ mode: SnapshotOptions.Mode, duration: Double) -> [Double] {
        switch mode {
        case .atTimes(let t): return t.filter { $0 >= 0 && $0 < max(duration, 0.001) }.sorted()
        case .every(let s):
            guard s > 0 else { return [] }
            return Array(stride(from: 0, to: duration, by: s))
        case .count(let n):
            guard n > 0, duration > 0 else { return [] }
            // Evenly spaced, avoiding the very first and last frame.
            return (0..<n).map { duration * (Double($0) + 0.5) / Double(n) }
        }
    }

    public static func snapshot(input: URL, output: URL, at time: Double) -> [String] {
        prefix + ["-ss", seconds(time), "-i", input.path, "-frames:v", "1", "-update", "1", output.path]
    }

    public static func mute(input: URL, output: URL) -> [String] {
        prefix + ["-i", input.path, "-map_metadata", "0", "-map", "0:v", "-c", "copy", "-an", output.path]
    }

    public static func stripMetadata(input: URL, output: URL) -> [String] {
        prefix + ["-i", input.path, "-map", "0", "-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1",
                  "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact", output.path]
    }

    public static func editMetadata(input: URL, output: URL, edit: MetadataEdit) -> [String] {
        var args = prefix + ["-i", input.path, "-map", "0", "-c", "copy"]
        args += edit.removeAll ? ["-map_metadata", "-1"] : ["-map_metadata", "0"]
        if edit.removeLocation { args += ["-metadata", "location=", "-metadata", "location-eng=", "-metadata", "com.apple.quicktime.location.ISO6709="] }
        if let t = edit.title { args += ["-metadata", "title=\(t)"] }
        if let a = edit.author { args += ["-metadata", "artist=\(a)", "-metadata", "author=\(a)"] }
        if let c = edit.comment { args += ["-metadata", "comment=\(c)"] }
        if let k = edit.keywords { args += ["-metadata", "keywords=\(k)"] }
        return args + [output.path]
    }

    public static func normalize(input: URL, output: URL, format: FileFormat, options: NormalizeOptions, info: MediaInfo) -> [String] {
        let filter = "loudnorm=I=\(fmt(options.targetLUFS)):TP=\(fmt(options.truePeak)):LRA=11"
        var args = prefix + ["-i", input.path, "-map_metadata", "0"]
        if format.kind == .video && info.hasVideo {
            // Video is copied untouched; only the audio is re-encoded.
            args += ["-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-af", filter]
            args += ["-c:a", format == .webm ? "libopus" : "aac", "-b:a", "192000"]
        } else {
            args += ["-map", "0:a:0", "-af", filter, "-ar", String(info.sampleRate ?? 48_000)] + encoderArguments(for: format, info: nil)
        }
        return args + [output.path]
    }

    public static func channelFilter(_ mode: ChannelMode) -> [String] {
        switch mode {
        case .mono: ["-ac", "1"]
        case .stereo: ["-ac", "2"]
        case .swap: ["-af", "pan=stereo|c0=c1|c1=c0"]
        case .leftOnly: ["-af", "pan=mono|c0=c0"]
        case .rightOnly: ["-af", "pan=mono|c0=c1"]
        }
    }

    public static func channels(input: URL, output: URL, format: FileFormat, mode: ChannelMode, info: MediaInfo) -> [String] {
        var enc = encoderArguments(for: format, info: nil)
        // Vorbis is stereo-only in FFmpeg; mono output from OGG must use Opus settings in the same container.
        if format == .ogg && (mode == .mono || mode == .leftOnly || mode == .rightOnly) {
            enc = ["-vn", "-c:a", "libopus", "-b:a", "96000"]
        } else if format == .ogg {
            enc = enc.filter { $0 != "-ac" && $0 != "2" }
        }
        return prefix + ["-i", input.path, "-map_metadata", "0", "-map", "0:a:0"] + channelFilter(mode) + enc + [output.path]
    }

    /// `between(t,a,b)+…` expression for a set of intervals.
    public static func intervalExpression(_ spans: [TimeSpan]) -> String {
        spans.map { "between(t,\(fmt($0.start)),\(fmt($0.end)))" }.joined(separator: "+")
    }

    public static func bleep(input: URL, output: URL, format: FileFormat, options: BleepOptions, info: MediaInfo) -> [String] {
        let expr = intervalExpression(options.intervals)
        let rate = info.sampleRate ?? 48_000
        var args = prefix + ["-i", input.path]
        let filter: String
        if options.frequency > 0 {
            args += ["-f", "lavfi", "-i", "sine=frequency=\(fmt(options.frequency)):sample_rate=\(rate)"]
            filter = "[0:a:0]volume=0:enable='\(expr)'[muted];[1:a]volume=0.25,volume=0:enable='not(\(expr))'[tone];[muted][tone]amix=inputs=2:duration=first:normalize=0[out]"
        } else {
            filter = "[0:a:0]volume=0:enable='\(expr)'[out]"
        }
        args += ["-filter_complex", filter, "-map_metadata", "0"]
        if format.kind == .video && info.hasVideo {
            args += ["-map", "0:v:0", "-map", "[out]", "-c:v", "copy", "-c:a", format == .webm ? "libopus" : "aac", "-b:a", "192000"]
        } else {
            args += ["-map", "[out]"] + encoderArguments(for: format, info: nil)
        }
        return args + [output.path]
    }

    /// Joins files with the concat filter (re-encodes, so different sources still line up).
    public static func join(inputs: [URL], output: URL, format: FileFormat, infos: [MediaInfo]) -> [String] {
        var args = prefix
        for url in inputs { args += ["-i", url.path] }
        let n = inputs.count
        let isVideo = format.kind == .video
        let withAudio = infos.allSatisfy(\.hasAudio)
        var graph = ""
        if isVideo {
            let w = infos.first?.width ?? 1280, h = infos.first?.height ?? 720
            let fps = infos.first?.frameRate.map { String(format: "%.3f", $0) } ?? "30"
            for i in 0..<n {
                graph += "[\(i):v:0]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p[v\(i)];"
                if withAudio { graph += "[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(i)];" }
            }
            for i in 0..<n { graph += "[v\(i)]" + (withAudio ? "[a\(i)]" : "") }
            graph += "concat=n=\(n):v=1:a=\(withAudio ? 1 : 0)[v]" + (withAudio ? "[a]" : "")
            args += ["-filter_complex", graph, "-map", "[v]"] + (withAudio ? ["-map", "[a]"] : [])
            args += encoderArguments(for: format, info: MediaInfo(videoCodec: "none", audioCodec: withAudio ? "none" : nil), allowCopy: false)
        } else {
            for i in 0..<n { graph += "[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(i)];" }
            for i in 0..<n { graph += "[a\(i)]" }
            graph += "concat=n=\(n):v=0:a=1[a]"
            args += ["-filter_complex", graph, "-map", "[a]"] + encoderArguments(for: format, info: nil)
        }
        args += ["-map_metadata", "0"]
        return args + [output.path]
    }

    // MARK: Helpers

    public static func seconds(_ s: Double) -> String { String(format: "%.3f", max(0, s)) }
    static func fmt(_ v: Double) -> String { String(format: "%.6g", v) }
}
