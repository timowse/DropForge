import Foundation

public struct ValidationError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum InputParsing {
    /// "1-3, 5, 7-" (1-based, inclusive; open end = last page) → zero-based index groups.
    public static func pageRanges(_ text: String, pageCount: Int) throws -> [[Int]] {
        guard pageCount > 0 else { throw ValidationError("The PDF has no pages.") }
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ValidationError("Enter page ranges such as 1-3, 5.") }
        return try parts.map { part in
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let lower: Int, upper: Int
            switch bounds.count {
            case 1:
                guard let v = Int(bounds[0]) else { throw ValidationError("“\(part)” is not a page number.") }
                lower = v; upper = v
            case 2:
                guard let l = bounds[0].isEmpty ? 1 : Int(bounds[0]),
                      let u = bounds[1].isEmpty ? pageCount : Int(bounds[1]) else {
                    throw ValidationError("“\(part)” is not a page range.")
                }
                lower = l; upper = u
            default:
                throw ValidationError("“\(part)” is not a page range.")
            }
            guard lower >= 1, upper <= pageCount, lower <= upper else {
                throw ValidationError("Pages \(part) are outside 1–\(pageCount).")
            }
            return Array((lower - 1)...(upper - 1))
        }
    }

    /// "75", "1:15", "1:02:03.5" → seconds.
    public static func time(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return FFmpegProgressParser.parseTimestamp(t)
    }

    /// "0:05-0:07, 1:10-1:12.5" → spans, validated against `duration`.
    public static func intervals(_ text: String, duration: Double?) throws -> [TimeSpan] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ValidationError("Add at least one interval, e.g. 0:05-0:07.") }
        let spans = try parts.map { part -> TimeSpan in
            let b = part.split(separator: "-").map(String.init)
            guard b.count == 2, let s = time(b[0]), let e = time(b[1]) else {
                throw ValidationError("“\(part)” is not an interval like 0:05-0:07.")
            }
            return TimeSpan(start: s, end: e)
        }
        for span in spans { try validate(span, duration: duration) }
        return spans.sorted { $0.start < $1.start }
    }

    /// "2.5 MB", "800k", "1.2GB", "500000" → bytes.
    public static func byteSize(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        let number = t.prefix(while: { $0.isNumber || $0 == "." })
        guard let value = Double(number), value > 0 else { return nil }
        let unit = t.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch unit {
        case "", "b", "bytes": multiplier = 1
        case "k", "kb", "kib": multiplier = 1_000
        case "m", "mb", "mib": multiplier = 1_000_000
        case "g", "gb", "gib": multiplier = 1_000_000_000
        default: return nil
        }
        return Int64(value * multiplier)
    }

    /// Comma separated list of times.
    public static func times(_ text: String) -> [Double]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var out: [Double] = []
        for p in parts {
            guard let v = time(p) else { return nil }
            out.append(v)
        }
        return out
    }

    public static func validate(_ span: TimeSpan, duration: Double?) throws {
        guard span.start >= 0, span.end > span.start else {
            throw ValidationError("The end must come after the start.")
        }
        if let duration, span.start >= duration {
            throw ValidationError("The start is after the end of the file (\(formatTime(duration))).")
        }
    }

    public static func formatTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600, m = (Int(total) % 3600) / 60
        let s = total - Double(h * 3600 + m * 60)
        if h > 0 { return String(format: "%d:%02d:%04.1f", h, m, s) }
        return String(format: "%d:%04.1f", m, s)
    }
}

public enum ParameterValidation {
    /// Checks editor output before a job starts, so errors surface in the editor instead of mid-batch.
    public static func validate(_ parameters: ToolParameters, selection: Selection, duration: Double? = nil) throws {
        switch parameters {
        case .compress(let o):
            switch o.mode {
            case .percent(let p) where !(1...99).contains(p):
                throw ValidationError("Choose a percentage between 1 and 99.")
            case .targetBytes(let b) where b < 1_000:
                throw ValidationError("The target size must be at least 1 KB.")
            case .targetBytes(let b) where selection.items.allSatisfy({ $0.byteSize > 0 && b >= $0.byteSize }):
                throw ValidationError("The target is not smaller than the file.")
            default: break
            }
            if let m = o.maxDimension, m < 16 { throw ValidationError("The maximum size must be at least 16 pixels.") }
        case .resize(let o):
            switch o.mode {
            case .scale(let p) where !(1...1000).contains(p): throw ValidationError("Scale must be between 1 % and 1000 %.")
            case .fit(let w, let h), .exact(let w, let h):
                guard (1...30_000).contains(w), (1...30_000).contains(h) else {
                    throw ValidationError("Width and height must be between 1 and 30000 pixels.")
                }
            default: break
            }
        case .crop(let o):
            guard o.rect.isValid else { throw ValidationError("The crop area is outside the image.") }
            if let w = o.outputWidth, w < 1 { throw ValidationError("Width must be positive.") }
            if let h = o.outputHeight, h < 1 { throw ValidationError("Height must be positive.") }
        case .trim(let span):
            try InputParsing.validate(span, duration: duration)
        case .speed(let f):
            guard (0.25...4).contains(f) else { throw ValidationError("Speed must be between 0.25× and 4×.") }
        case .split(let o):
            switch o.mode {
            case .equalParts(let n) where !(2...100).contains(n): throw ValidationError("Split into 2 to 100 parts.")
            case .every(let s) where s < 1: throw ValidationError("Parts must be at least one second long.")
            case .atTimes(let t) where t.isEmpty: throw ValidationError("Add at least one split time.")
            default: break
            }
        case .snapshot(let o):
            switch o.mode {
            case .count(let n) where !(1...500).contains(n): throw ValidationError("Take between 1 and 500 snapshots.")
            case .every(let s) where s < 0.1: throw ValidationError("The interval must be at least 0.1 seconds.")
            case .atTimes(let t) where t.isEmpty: throw ValidationError("Add at least one time.")
            default: break
            }
        case .bleep(let o):
            guard !o.intervals.isEmpty else { throw ValidationError("Add at least one interval to bleep.") }
            for i in o.intervals { try InputParsing.validate(i, duration: duration) }
        case .collage(let o):
            guard (1...20).contains(o.columns) else { throw ValidationError("Use 1 to 20 columns.") }
            guard (200...20_000).contains(o.width) else { throw ValidationError("Width must be 200 to 20000 pixels.") }
            guard (0...500).contains(o.spacing) else { throw ValidationError("Spacing must be 0 to 500 pixels.") }
        case .organize(let o):
            guard !o.pages.isEmpty else { throw ValidationError("Keep at least one page.") }
        case .annotate(let o):
            guard !o.annotations.isEmpty else { throw ValidationError("Add at least one mark before saving.") }
        case .redact(let o):
            guard !o.regions.isEmpty || o.pageRegions.values.contains(where: { !$0.isEmpty }) else {
                throw ValidationError("Mark at least one area to redact.")
            }
        case .metadata(let m):
            guard m.hasEdits || m.removeAll || m.removeLocation else { throw ValidationError("Nothing was changed.") }
        default:
            break
        }
    }
}
