import Foundation

/// A tiny CommonMark-ish renderer covering what documents actually use: headings, paragraphs,
/// emphasis, code, links, images, lists, quotes, rules, fenced code and pipe tables.
public enum MarkdownHTML {
    public static func document(fromMarkdown md: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font-family:-apple-system,Helvetica,sans-serif;line-height:1.5;max-width:46em;margin:2em auto;padding:0 1em}
        pre{background:#f4f4f4;padding:.8em;overflow:auto}code{font-family:Menlo,monospace}
        table{border-collapse:collapse}td,th{border:1px solid #bbb;padding:.3em .6em}blockquote{color:#555;border-left:3px solid #ccc;margin-left:0;padding-left:1em}</style>
        </head><body>
        \(body(fromMarkdown: md))
        </body></html>
        """
    }

    public static func body(fromMarkdown md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html: [String] = []
        var i = 0
        var paragraph: [String] = []
        func flushParagraph() {
            if !paragraph.isEmpty {
                html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
                paragraph.removeAll()
            }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                i += 1
                continue
            }
            if let level = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inline(text))</h\(level)>")
                i += 1; continue
            }
            if isRule(trimmed) { flushParagraph(); html.append("<hr>"); i += 1; continue }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                html.append("<blockquote>\(body(fromMarkdown: quote.joined(separator: "\n")))</blockquote>")
                continue
            }
            if listMarker(trimmed) != nil {
                flushParagraph()
                let ordered = listMarker(trimmed)!.ordered
                var items: [String] = []
                while i < lines.count, let m = listMarker(lines[i].trimmingCharacters(in: .whitespaces)), m.ordered == ordered {
                    items.append("<li>\(inline(m.content))</li>")
                    i += 1
                }
                let tag = ordered ? "ol" : "ul"
                html.append("<\(tag)>\(items.joined())</\(tag)>")
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(tableCells(lines[i])); i += 1
                }
                var t = "<table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                for r in rows { t += "<tr>" + r.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
                html.append(t + "</tbody></table>")
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return html.joined(separator: "\n")
    }

    static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    static func isRule(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (Set(compact) == ["-"] || Set(compact) == ["*"] || Set(compact) == ["_"])
    }

    static func listMarker(_ s: String) -> (ordered: Bool, content: String)? {
        for bullet in ["- ", "* ", "+ "] where s.hasPrefix(bullet) {
            return (false, String(s.dropFirst(2)))
        }
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count < 10 {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (true, String(rest.dropFirst(2))) }
        }
        return nil
    }

    static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    static func tableCells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline markup. Code spans are protected from further processing.
    static func inline(_ raw: String) -> String {
        var codeSpans: [String] = []
        var literals: [Character] = []
        var s = ""
        var inCode = false
        var current = ""
        var escapeNext = false
        for ch in raw {
            if escapeNext {
                escapeNext = false
                if "\\`*_{}[]()#+-.!>|~".contains(ch) {
                    literals.append(ch)
                    s += "\u{1}\(literals.count - 1)\u{1}"
                    continue
                }
                s.append("\\")
            }
            if ch == "\\" && !inCode {
                escapeNext = true
            } else if ch == "`" {
                if inCode {
                    codeSpans.append(current)
                    s += "\u{0}\(codeSpans.count - 1)\u{0}"
                    current = ""
                }
                inCode.toggle()
            } else if inCode {
                current.append(ch)
            } else {
                s.append(ch)
            }
        }
        if inCode { s += "`" + current }
        s = escape(s)
        s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)\s]+)\)"#, with: "<img alt=\"$1\" src=\"$2\">", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"__(.+?)__"#, with: "<strong>$1</strong>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "<em>$1</em>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, with: "<em>$1</em>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~(.+?)~~"#, with: "<del>$1</del>", options: .regularExpression)
        for (i, code) in codeSpans.enumerated() {
            s = s.replacingOccurrences(of: "\u{0}\(i)\u{0}", with: "<code>\(escape(code))</code>")
        }
        for (i, ch) in literals.enumerated() {
            s = s.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: escape(String(ch)))
        }
        if escapeNext { s += "\\" }
        return s
    }
}

/// Neutral rich-text model so any attributed text can be written as Markdown.
public struct RichRun: Sendable, Hashable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public var link: String?
    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.code = code; self.link = link
    }
}

public struct RichParagraph: Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        case body
        case heading(Int)
        case bullet(level: Int)
        case numbered(level: Int, number: Int)
        case quote
        case code
    }
    public var style: Style
    public var runs: [RichRun]
    public init(style: Style, runs: [RichRun]) { self.style = style; self.runs = runs }
    public var plainText: String { runs.map(\.text).joined() }
}

public enum MarkdownWriter {
    public static func render(_ paragraphs: [RichParagraph]) -> String {
        var out: [String] = []
        var previousWasList = false
        for p in paragraphs {
            let text = p.style == .code ? p.plainText : renderRuns(p.runs)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let line: String
            var isList = false
            switch p.style {
            case .body: line = escapeLineStart(text)
            case .heading(let l): line = String(repeating: "#", count: min(max(l, 1), 6)) + " " + text
            case .bullet(let level): line = String(repeating: "  ", count: level) + "- " + text; isList = true
            case .numbered(let level, let n): line = String(repeating: "  ", count: level) + "\(n). " + text; isList = true
            case .quote: line = "> " + text
            case .code: line = "```\n" + text + "\n```"
            }
            if !out.isEmpty && !(isList && previousWasList) { out.append("") }
            out.append(line)
            previousWasList = isList
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func renderRuns(_ runs: [RichRun]) -> String {
        var merged: [RichRun] = []
        for r in runs {
            if var last = merged.last, last.bold == r.bold, last.italic == r.italic, last.code == r.code, last.link == r.link {
                last.text += r.text
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged.map { r in
            let raw = r.text.replacingOccurrences(of: "\n", with: " ")
            if r.code { return "`\(raw)`" }
            // Keep surrounding spaces outside the markers so "**word** " stays valid.
            let leading = String(raw.prefix(while: \.isWhitespace))
            let trailing = String(raw.reversed().prefix(while: \.isWhitespace))
            var core = raw.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return raw }
            core = escapeInline(core)
            if r.bold && r.italic { core = "***\(core)***" }
            else if r.bold { core = "**\(core)**" }
            else if r.italic { core = "*\(core)*" }
            if let link = r.link { core = "[\(core)](\(link))" }
            return leading + core + trailing
        }.joined()
    }

    static func escapeInline(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "*_`[]\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func escapeLineStart(_ s: String) -> String {
        if MarkdownHTML.headingLevel(s) != nil || MarkdownHTML.listMarker(s) != nil || s.hasPrefix(">") {
            return "\\" + s
        }
        return s
    }
}
