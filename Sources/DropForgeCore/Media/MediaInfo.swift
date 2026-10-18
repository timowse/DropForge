import Foundation

/// What ffprobe reports about a media file (only the fields DropForge uses).
public struct MediaInfo: Sendable, Hashable {
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var audioChannels: Int?
    public var sampleRate: Int?
    public var frameRate: Double?
    public var bitRate: Int?
    public var formatName: String?
    public var tags: [String: String]

    public init(duration: Double? = nil, width: Int? = nil, height: Int? = nil, videoCodec: String? = nil,
                audioCodec: String? = nil, audioChannels: Int? = nil, sampleRate: Int? = nil, frameRate: Double? = nil,
                bitRate: Int? = nil, formatName: String? = nil, tags: [String: String] = [:]) {
        self.duration = duration; self.width = width; self.height = height; self.videoCodec = videoCodec
        self.audioCodec = audioCodec; self.audioChannels = audioChannels; self.sampleRate = sampleRate
        self.frameRate = frameRate; self.bitRate = bitRate; self.formatName = formatName; self.tags = tags
    }

    public var hasVideo: Bool { videoCodec != nil }
    public var hasAudio: Bool { audioCodec != nil }
}

public enum FFprobeParser {
    private struct Root: Decodable {
        let streams: [Stream]?
        let format: Format?
    }
    private struct Stream: Decodable {
        let codec_type: String?
        let codec_name: String?
        let width: Int?
        let height: Int?
        let channels: Int?
        let sample_rate: String?
        let avg_frame_rate: String?
        let r_frame_rate: String?
        let duration: String?
        let disposition: [String: Int]?
    }
    private struct Format: Decodable {
        let duration: String?
        let bit_rate: String?
        let format_name: String?
        let tags: [String: String]?
    }

    public static func parse(_ data: Data) throws -> MediaInfo {
        let root = try JSONDecoder().decode(Root.self, from: data)
        var info = MediaInfo()
        info.formatName = root.format?.format_name
        info.duration = root.format?.duration.flatMap(Double.init)
        info.bitRate = root.format?.bit_rate.flatMap(Int.init)
        info.tags = root.format?.tags ?? [:]
        for s in root.streams ?? [] {
            switch s.codec_type {
            case "video" where info.videoCodec == nil:
                // Cover art in audio files is an "attached picture", not video.
                if s.disposition?["attached_pic"] == 1 { continue }
                info.videoCodec = s.codec_name
                info.width = s.width
                info.height = s.height
                info.frameRate = parseRate(s.avg_frame_rate) ?? parseRate(s.r_frame_rate)
                if info.duration == nil { info.duration = s.duration.flatMap(Double.init) }
            case "audio" where info.audioCodec == nil:
                info.audioCodec = s.codec_name
                info.audioChannels = s.channels
                info.sampleRate = s.sample_rate.flatMap(Int.init)
                if info.duration == nil { info.duration = s.duration.flatMap(Double.init) }
            default: break
            }
        }
        return info
    }

    static func parseRate(_ s: String?) -> Double? {
        guard let s else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0, n != 0 { return n / d }
        return Double(s).flatMap { $0 > 0 ? $0 : nil }
    }

    public static func arguments(for input: URL) -> [String] {
        ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", input.path]
    }
}

/// Parses `ffmpeg -progress pipe:1` key=value output into a 0...1 fraction.
public struct FFmpegProgressParser: Sendable {
    public let totalDuration: Double?
    public private(set) var fraction: Double = 0
    public private(set) var finished = false

    public init(totalDuration: Double?) {
        self.totalDuration = totalDuration
    }

    /// Feeds one line. Returns the new fraction when it changed.
    @discardableResult
    public mutating func consume(_ line: String) -> Double? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "out_time_us", "out_time_ms":
            // ffmpeg reports microseconds under both keys.
            guard let us = Double(value), us >= 0 else { return nil }
            return update(seconds: us / 1_000_000)
        case "out_time":
            guard let s = Self.parseTimestamp(value) else { return nil }
            return update(seconds: s)
        case "progress":
            if value == "end" {
                finished = true
                fraction = 1
                return 1
            }
            return nil
        default:
            return nil
        }
    }

    private mutating func update(seconds: Double) -> Double? {
        guard let total = totalDuration, total > 0 else { return nil }
        let f = min(max(seconds / total, 0), 0.999)
        guard f > fraction else { return nil }
        fraction = f
        return f
    }

    /// "HH:MM:SS.micro" or "MM:SS" or "SS.s" → seconds.
    public static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}
