import Foundation

/// RFC 4180 style CSV and TSV reading/writing.
public enum DelimitedText {
    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        var sawAny = false
        while let ch = next() {
            sawAny = true
            if inQuotes {
                if ch == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == delimiter {
                row.append(field); field = ""
            } else if ch == "\n" || ch == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(ch)
            }
        }
        if sawAny && (!field.isEmpty || !row.isEmpty) {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    public static func write(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { row in
            row.map { quote($0, delimiter: delimiter) }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    static func quote(_ field: String, delimiter: Character) -> String {
        let needs = field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r")
        guard needs else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Guesses the delimiter of an unknown text table.
    public static func sniffDelimiter(_ sample: String) -> Character {
        let firstLine = sample.split(separator: "\n").first.map(String.init) ?? sample
        let counts: [(Character, Int)] = [",", "\t", ";"].map { d in (d, firstLine.filter { $0 == d }.count) }
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return "," }
        return best.0
    }

    /// Converts CSV ↔ TSV.
    public static func convert(_ text: String, from: Character, to: Character) -> String {
        write(parse(text, delimiter: from), delimiter: to)
    }
}
