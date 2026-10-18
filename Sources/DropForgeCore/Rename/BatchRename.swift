import Foundation

/// Rename template. Tokens: `{name}` original name, `{n}` sequence, `{date}` today, `{created}`, `{modified}`,
/// `{parent}` enclosing folder, `{ext}` original extension (the extension is always kept anyway).
public struct RenamePattern: Sendable, Hashable, Codable {
    public enum CaseMode: String, Sendable, Hashable, Codable, CaseIterable {
        case keep, lower, upper, title
    }
    public var template: String
    public var find: String
    public var replace: String
    public var useRegex: Bool
    public var caseMode: CaseMode
    public var startNumber: Int
    public var padding: Int
    public var dateFormat: String

    public init(template: String = "{name}", find: String = "", replace: String = "", useRegex: Bool = false,
                caseMode: CaseMode = .keep, startNumber: Int = 1, padding: Int = 2, dateFormat: String = "yyyy-MM-dd") {
        self.template = template; self.find = find; self.replace = replace; self.useRegex = useRegex
        self.caseMode = caseMode; self.startNumber = startNumber; self.padding = padding; self.dateFormat = dateFormat
    }

    public static let tokens = ["{name}", "{n}", "{date}", "{created}", "{modified}", "{parent}", "{ext}"]
}

public struct RenamePlanItem: Sendable, Hashable {
    public let source: URL
    public let newName: String
    public var destination: URL { source.deletingLastPathComponent().appendingPathComponent(newName) }
    public var changes: Bool { newName != source.lastPathComponent }
}

public enum RenameError: Error, Equatable, LocalizedError {
    case invalidRegex(String)
    case emptyName(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRegex(let p): "“\(p)” is not a valid regular expression."
        case .emptyName(let n): "The pattern makes an empty name for “\(n)”."
        }
    }
}

public enum RenamePlanner {
    public struct FileDates: Sendable {
        public var created: Date?
        public var modified: Date?
        public init(created: Date?, modified: Date?) { self.created = created; self.modified = modified }
    }

    /// Plans new names. Names stay unique within each folder, never collide with unrelated existing files,
    /// and keep their extensions.
    public static func plan(_ urls: [URL], pattern: RenamePattern, now: Date = Date(),
                            dates: (URL) -> FileDates = RenamePlanner.fileDates,
                            exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> [RenamePlanItem] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern.dateFormat.isEmpty ? "yyyy-MM-dd" : pattern.dateFormat
        var regex: NSRegularExpression?
        if pattern.useRegex && !pattern.find.isEmpty {
            do { regex = try NSRegularExpression(pattern: pattern.find) } catch { throw RenameError.invalidRegex(pattern.find) }
        }
        let batch = Set(urls.map { $0.standardizedFileURL.path })
        var claimed: [String: Set<String>] = [:]   // folder → lower-cased names taken
        var plan: [RenamePlanItem] = []
        for (index, url) in urls.enumerated() {
            let ext = url.pathExtension
            var stem = OutputNaming.stem(of: url)
            if !pattern.find.isEmpty {
                if let regex {
                    stem = regex.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem),
                                                          withTemplate: pattern.replace)
                } else {
                    stem = stem.replacingOccurrences(of: pattern.find, with: pattern.replace)
                }
            }
            let d = dates(url)
            let number = String(format: "%0\(max(1, min(pattern.padding, 8)))d", pattern.startNumber + index)
            var name = pattern.template.isEmpty ? "{name}" : pattern.template
            let replacements: [(String, String)] = [
                ("{name}", stem), ("{n}", number), ("{date}", formatter.string(from: now)),
                ("{created}", d.created.map(formatter.string) ?? ""), ("{modified}", d.modified.map(formatter.string) ?? ""),
                ("{parent}", url.deletingLastPathComponent().lastPathComponent), ("{ext}", ext),
            ]
            for (token, value) in replacements { name = name.replacingOccurrences(of: token, with: value) }
            switch pattern.caseMode {
            case .keep: break
            case .lower: name = name.lowercased()
            case .upper: name = name.uppercased()
            case .title: name = name.capitalized
            }
            name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasPrefix(".") { name.removeFirst() }
            guard !name.isEmpty else { throw RenameError.emptyName(url.lastPathComponent) }

            let folder = url.deletingLastPathComponent().standardizedFileURL.path
            var taken = claimed[folder] ?? []
            var attempt = 1
            var candidate = OutputNaming.candidate(base: name, extension: ext, attempt: attempt)
            func blocked(_ c: String) -> Bool {
                if taken.contains(c.lowercased()) { return true }
                let target = URL(fileURLWithPath: folder).appendingPathComponent(c).standardizedFileURL
                // Existing files outside the batch block the name; files inside the batch will move away.
                return exists(target) && !batch.contains(target.path) && target.path.lowercased() != url.standardizedFileURL.path.lowercased()
            }
            while blocked(candidate) {
                attempt += 1
                candidate = OutputNaming.candidate(base: name, extension: ext, attempt: attempt)
            }
            taken.insert(candidate.lowercased())
            claimed[folder] = taken
            plan.append(RenamePlanItem(source: url, newName: candidate))
        }
        return plan
    }

    public static func fileDates(_ url: URL) -> FileDates {
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return FileDates(created: v?.creationDate, modified: v?.contentModificationDate)
    }
}
