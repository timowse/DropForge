import Foundation
import DropForgeCore

public enum OfficeError: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case automationDenied(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let app): "\(app) is not installed."
        case .automationDenied(let app):
            "macOS did not allow DropForge to control \(app). Allow it in System Settings › Privacy & Security › Automation, or install LibreOffice."
        case .conversionFailed(let detail): "The office conversion failed. \(detail)"
        }
    }
}

/// LibreOffice (headless, isolated profile) and Keynote/Pages/Numbers (Apple Events via osascript).
public struct OfficeEngine: Sendable {
    public let runner: ProcessRunning
    public let locator: EngineLocator
    /// Persistent LibreOffice profile owned by DropForge, so a running LibreOffice is never disturbed.
    public let profileDirectory: URL

    public init(runner: ProcessRunning = SystemProcessRunner(), locator: EngineLocator = EngineLocator(),
                profileDirectory: URL? = nil) {
        self.runner = runner
        self.locator = locator
        self.profileDirectory = profileDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropForge/LibreOfficeProfile", isDirectory: true)
    }

    // MARK: LibreOffice

    /// `--convert-to` filter for an output format.
    public static func libreOfficeFilter(for format: FileFormat, sourceKind: FileKind) -> String? {
        switch format {
        case .pdf:
            switch sourceKind {
            case .spreadsheet: "pdf:calc_pdf_Export"
            case .slides: "pdf:impress_pdf_Export"
            default: "pdf:writer_pdf_Export"
            }
        case .docx: "docx:MS Word 2007 XML"
        case .odt: "odt"
        case .xlsx: "xlsx:Calc MS Excel 2007 XML"
        case .ods: "ods"
        case .csv: "csv:Text - txt - csv (StarCalc):44,34,76,1"
        case .tsv: "csv:Text - txt - csv (StarCalc):9,34,76,1"
        case .pptx: "pptx:Impress MS PowerPoint 2007 XML"
        case .txt: "txt:Text (encoded):UTF8"
        case .html: "html"
        case .epub: "epub"
        default: nil
        }
    }

    public static func libreOfficeArguments(input: URL, format: FileFormat, sourceFormat: FileFormat?, outDir: URL,
                                            profile: URL) -> [String]? {
        guard let filter = libreOfficeFilter(for: format, sourceKind: sourceFormat?.kind ?? .document) else { return nil }
        var args = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore", "--nolockcheck",
                    "--nodefault", "--nologo", "--convert-to", filter, "--outdir", outDir.path]
        switch sourceFormat {
        case .csv: args += ["--infilter=CSV:44,34,76,1"]
        case .tsv: args += ["--infilter=CSV:9,34,76,1"]
        default: break
        }
        return args + [input.path]
    }

    /// Converts with LibreOffice and returns the produced file (inside `workspace`).
    public func libreOffice(_ input: URL, to format: FileFormat, workspace: JobWorkspace) async throws -> URL {
        guard let soffice = locator.soffice else { throw OfficeError.notInstalled("LibreOffice") }
        let outDir = try workspace.subdirectory("lo-out")
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        // LibreOffice derives the output name from the input; stage a copy with a plain ASCII name.
        let staged = workspace.file("source.\(input.pathExtension.isEmpty ? "dat" : input.pathExtension)")
        try FileManager.default.copyItem(at: input, to: staged)
        guard let args = Self.libreOfficeArguments(input: staged, format: format, sourceFormat: FileFormat.detect(input),
                                                   outDir: outDir, profile: profileDirectory) else {
            throw OfficeError.conversionFailed("LibreOffice cannot write \(format.label).")
        }
        let result = try await runner.run(Command(executable: soffice, arguments: args, environment: ["HOME": NSHomeDirectory()]))
        let produced = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        guard result.exitCode == 0, let file = produced.first(where: { !$0.lastPathComponent.hasPrefix(".") }) else {
            throw OfficeError.conversionFailed(ErrorText.lastMeaningfulLine(result.stderr + "\n" + result.stdoutString))
        }
        return file
    }

    // MARK: iWork

    /// AppleScript that opens argv[1] in `app` and exports to argv[2] using `exportClause`.
    static func iWorkScript(app: String, exportClause: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "set inFile to POSIX file (item 1 of argv)",
            "-e", "set outFile to POSIX file (item 2 of argv)",
            "-e", "tell application \"\(app)\"",
            "-e", "set theDoc to open inFile",
            "-e", "export theDoc to outFile as \(exportClause)",
            "-e", "close theDoc saving no",
            "-e", "end tell",
            "-e", "end run",
        ]
    }

    public static func iWorkExportClause(app: EngineRequirement, format: FileFormat) -> String? {
        switch (app, format) {
        case (_, .pdf): "PDF"
        case (.pages, .docx): "Microsoft Word"
        case (.pages, .txt): "unformatted text"
        case (.pages, .epub): "EPUB"
        case (.numbers, .xlsx): "Microsoft Excel"
        case (.numbers, .csv): "CSV"
        case (.keynote, .pptx): "Microsoft PowerPoint"
        default: nil
        }
    }

    public static func appName(_ engine: EngineRequirement) -> String {
        switch engine {
        case .keynote: "Keynote"
        case .pages: "Pages"
        case .numbers: "Numbers"
        default: engine.displayName
        }
    }

    public func iWork(_ engine: EngineRequirement, input: URL, to format: FileFormat, workspace: JobWorkspace) async throws -> URL {
        let name = Self.appName(engine)
        guard locator.application(engine) != nil else { throw OfficeError.notInstalled(name) }
        guard let clause = Self.iWorkExportClause(app: engine, format: format) else {
            throw OfficeError.conversionFailed("\(name) cannot export \(format.label).")
        }
        let out = workspace.file("export.\(format.preferredExtension)")
        let args = Self.iWorkScript(app: name, exportClause: clause) + [input.path, out.path]
        let result = try await runner.run(Command(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: args))
        if result.exitCode != 0 {
            // -1743: the user (or policy) denied Automation; -600: the app could not be launched.
            if result.stderr.contains("-1743") || result.stderr.lowercased().contains("not authorized") {
                throw OfficeError.automationDenied(name)
            }
            throw OfficeError.conversionFailed(ErrorText.lastMeaningfulLine(result.stderr))
        }
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw OfficeError.conversionFailed("\(name) did not write a file.")
        }
        return out
    }
}
