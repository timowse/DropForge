import Foundation

/// Writes well-formed XHTML (EPUB requires XML) from the neutral rich-text model.
public enum RichXHTML {
    public static func escape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        // Strip characters XML 1.0 forbids.
        out.unicodeScalars.removeAll { s in
            let v = s.value
            return v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D
        }
        return out
    }

    public static func body(_ paragraphs: [RichParagraph]) -> String {
        var html: [String] = []
        var openList: String?
        func closeList() {
            if let l = openList { html.append("</\(l)>"); openList = nil }
        }
        for p in paragraphs {
            let content = p.style == .code ? escape(p.plainText) : runs(p.runs)
            if content.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            switch p.style {
            case .bullet, .numbered:
                let tag: String = { if case .bullet = p.style { return "ul" } ; return "ol" }()
                if openList != tag { closeList(); html.append("<\(tag)>"); openList = tag }
                html.append("<li>\(content)</li>")
                continue
            default:
                closeList()
            }
            switch p.style {
            case .heading(let l): let l = min(max(l, 1), 6); html.append("<h\(l)>\(content)</h\(l)>")
            case .quote: html.append("<blockquote><p>\(content)</p></blockquote>")
            case .code: html.append("<pre><code>\(content)</code></pre>")
            default: html.append("<p>\(content)</p>")
            }
        }
        closeList()
        return html.joined(separator: "\n")
    }

    static func runs(_ runs: [RichRun]) -> String {
        runs.map { r in
            var s = escape(r.text).replacingOccurrences(of: "\n", with: "<br/>")
            if r.code { s = "<code>\(s)</code>" }
            if r.italic { s = "<em>\(s)</em>" }
            if r.bold { s = "<strong>\(s)</strong>" }
            if let link = r.link { s = "<a href=\"\(escape(link))\">\(s)</a>" }
            return s
        }.joined()
    }

    public static func page(title: String, body: String, stylesheet: String? = nil) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>\(escape(title))</title>\(stylesheet.map { "<link rel=\"stylesheet\" type=\"text/css\" href=\"\($0)\"/>" } ?? "")</head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Splits paragraphs into chapters at level-1 headings (or level-2 when there are no level-1 headings).
    public static func chapters(_ paragraphs: [RichParagraph], fallbackTitle: String) -> [(title: String, paragraphs: [RichParagraph])] {
        let levels = paragraphs.compactMap { p -> Int? in if case .heading(let l) = p.style { return l } ; return nil }
        guard let splitLevel = levels.min(), levels.filter({ $0 == splitLevel }).count > 1 else {
            let title = paragraphs.first(where: { if case .heading = $0.style { return true } ; return false })?.plainText ?? fallbackTitle
            return [(title, paragraphs)]
        }
        var chapters: [(String, [RichParagraph])] = []
        var current: [RichParagraph] = []
        var currentTitle = fallbackTitle
        for p in paragraphs {
            if case .heading(let l) = p.style, l == splitLevel, !current.isEmpty {
                chapters.append((currentTitle, current))
                current = []
            }
            if case .heading(let l) = p.style, l == splitLevel { currentTitle = p.plainText }
            current.append(p)
        }
        if !current.isEmpty { chapters.append((currentTitle, current)) }
        return chapters
    }
}
