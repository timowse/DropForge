import Foundation

public struct SubtitleCue: Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public enum SubtitleError: Error, Equatable, LocalizedError {
    case noCues
    public var errorDescription: String? { "No subtitle cues were found in this file." }
}

/// SRT / WebVTT parsing and writing.
public enum Subtitles {
    public static func parse(_ raw: String) throws -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1].split(separator: " ").first.map(String.init) ?? parts[1])
            else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues }
        return cues
    }

    /// Accepts "00:01:02,345", "00:01:02.345", "01:02.345".
    public static func parseTime(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func stamp(_ t: Double, separator: Character) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, f = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, String(separator), f)
    }

    public static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start, separator: ",")) --> \(stamp(c.end, separator: ","))\n\(stripTags(c.text))\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { c in
            "\(stamp(c.start, separator: ".")) --> \(stamp(c.end, separator: "."))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    /// Plain transcript: one cue per line, markup removed, consecutive duplicates dropped.
    public static func plainText(_ cues: [SubtitleCue]) -> String {
        var out: [String] = []
        for c in cues {
            let line = stripTags(c.text).replacingOccurrences(of: "\n", with: " ")
            if out.last != line { out.append(line) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "{\\\\[^}]*}", with: "", options: .regularExpression)
    }
}
