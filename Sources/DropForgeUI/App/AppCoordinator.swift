import AppKit
import SwiftUI
import DropForgeCore
import DropForgeEngines

public enum AutomationChoice: Sendable { case allow, useFallback, cancel }

/// Everything that would show a modal dialog. Replaced by a scripted fake in UI tests.
@MainActor
public protocol UserPrompts: AnyObject {
    func confirmAutomation(app: String, purpose: String, fallback: String?) -> AutomationChoice
    func chooseFolder(prompt: String) -> URL?
    func chooseFiles() -> [URL]
    func showMessage(title: String, text: String, copyable: String?)
}

public enum FinderSelectionResult: Equatable, Sendable {
    case files([URL])
    case nothingSelected
    case denied
    case unavailable(String)
}

/// Reads the Finder selection (Apple Events). Replaced in tests.
public protocol FinderSelectionProviding: Sendable {
    func selection() async -> FinderSelectionResult
}

public struct OsascriptFinderSelection: FinderSelectionProviding {
    let runner: ProcessRunning
    public init(runner: ProcessRunning = SystemProcessRunner()) { self.runner = runner }

    public func selection() async -> FinderSelectionResult {
        let script = [
            "-e", "tell application \"Finder\"",
            "-e", "set out to \"\"",
            "-e", "repeat with i in (get selection)",
            "-e", "set out to out & POSIX path of (i as alias) & linefeed",
            "-e", "end repeat",
            "-e", "end tell",
            "-e", "return out",
        ]
        guard let result = try? await runner.run(Command(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: script)) else {
            return .unavailable("osascript could not run.")
        }
        if result.exitCode != 0 {
            return result.stderr.contains("-1743") ? .denied : .unavailable(ErrorText.lastMeaningfulLine(result.stderr))
        }
        let urls = result.stdoutString.split(whereSeparator: \.isNewline).map { URL(fileURLWithPath: String($0)) }
        return urls.isEmpty ? .nothingSelected : .files(urls)
    }
}

/// Real dialogs.
@MainActor
public final class SystemPrompts: UserPrompts {
    public init() {}

    public func confirmAutomation(app: String, purpose: String, fallback: String?) -> AutomationChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow DropForge to use \(app)?"
        alert.informativeText = "\(purpose)\n\nmacOS will ask you once to let DropForge control \(app). DropForge only opens the file you chose, exports it, and closes it without saving. You can change this later in System Settings › Privacy & Security › Automation."
        alert.addButton(withTitle: "Continue")
        if let fallback { alert.addButton(withTitle: fallback) }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allow
        case .alertSecondButtonReturn: return fallback == nil ? .cancel : .useFallback
        default: return .cancel
        }
    }

    public func chooseFolder(prompt: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    public func chooseFiles() -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose the files or folders DropForge should work on."
        return panel.runModal() == .OK ? panel.urls : []
    }

    public func showMessage(title: String, text: String, copyable: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if copyable != nil { alert.addButton(withTitle: "Copy") }
        if alert.runModal() == .alertSecondButtonReturn, let copyable {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyable, forType: .string)
        }
    }
}

/// Glue between input (drag gestures, menu, Services, hot key), choosers (wheel, picker), editors and jobs.
@MainActor
public final class AppCoordinator {
    public let settings: AppSettings
    public let locator: EngineLocator
    public let jobs = JobCenter()
    public let shelf = ShelfController()
    public let prompts: UserPrompts
    public let finder: FinderSelectionProviding
    let performer: UnitPerformer
    public private(set) var dragMonitor: DragMonitor
    public private(set) lazy var progress = ProgressWindowController(center: jobs)
    lazy var settingsWindow = SettingsWindowController(settings: settings, locator: locator)
    public private(set) var wheel: WheelController?
    public private(set) var picker: PickerWindowController?
    public private(set) var editors: [EditorWindowController] = []
    private var hotKey: HotKey?
    private var welcome: NSWindow?
    /// Overridden in tests to avoid real windows.
    public var showsWindows = true
    /// Overridden in tests so the user's clipboard is never touched.
    public var pasteboard: NSPasteboard = .general
    /// Test hook: the last validation message or notice shown to the user.
    public private(set) var lastNotice: String?
    /// Set by the executable when Sparkle is available. The UI target stays independently testable.
    public var checkForUpdates: (() -> Void)?

    public init(settings: AppSettings, locator: EngineLocator = EngineLocator(), performer: UnitPerformer? = nil,
                prompts: UserPrompts? = nil, finder: FinderSelectionProviding = OsascriptFinderSelection()) {
        self.settings = settings
        self.locator = locator
        self.performer = performer ?? DefaultPerformer(locator: locator, pdfExportDPI: settings.pdfExportDPI)
        self.prompts = prompts ?? SystemPrompts()
        self.finder = finder
        dragMonitor = DragMonitor(settings: settings.gestures, enabled: settings.dragGesturesEnabled)
        dragMonitor.onEvent = { [weak self] in self?.handle($0) }
        jobs.onJobStarted = { [weak self] _ in if self?.showsWindows == true { self?.progress.show() } }
        jobs.onJobFinished = { [weak self] in self?.jobFinished($0) }
    }

    public func start() {
        dragMonitor.start()
        updateHotKey()
        if !settings.hasSeenWelcome { showWelcome() }
        WorkspaceJanitor.sweep()
    }

    /// Applies changed settings to running services.
    public func settingsChanged() {
        dragMonitor.detector.settings = settings.gestures
        dragMonitor.detector.enabled = settings.dragGesturesEnabled
        updateHotKey()
    }

    func updateHotKey() {
        if settings.hotKeyEnabled, hotKey == nil {
            hotKey = HotKey { [weak self] in self?.openFinderSelection() }
        } else if !settings.hotKeyEnabled {
            hotKey?.unregister()
            hotKey = nil
        }
    }

    public func resolver(excluding: Set<EngineRequirement> = []) -> CapabilityResolver {
        var availability = locator.availability()
        availability.available.subtract(excluding)
        return CapabilityResolver(availability: availability)
    }

    var wheelScale: CGFloat { settings.wheelSize == .large ? Tokens.Wheel.largeScale : 1 }

    // MARK: - Drag gestures (F01–F04)

    public func handle(_ event: DragGestureEvent) {
        switch event {
        case .dragStarted:
            break
        case .open(let category, let point):
            let contents = DragContents.read(NSPasteboard(name: .drag))
            openWheel(category: category, at: point, selection: contents.provisionalSelection, mode: .drag)
        case .switchTo(let category):
            wheel?.model.switchTo(category)
        case .dragEnded:
            // The drop (if any) is delivered before or right after the button comes up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, let wheel = self.wheel, wheel.model.mode == .drag else { return }
                if wheel.model.phase == .visible { wheel.model.cancel() }
                self.dragMonitor.detector.wheelClosed()
            }
        }
    }

    // MARK: - Choosers

    public func openWheel(category: OperationCategory, at point: CGPoint, selection: Selection?, mode: WheelModel.Mode) {
        wheel?.hide()
        let model = WheelModel(mode: mode, category: category, resolver: resolver(), gestures: settings.gestures,
                               outputLocation: settings.outputLocation)
        let controller = WheelController(model: model, scale: wheelScale)
        model.onCommit = { [weak self, weak controller] d, sel in
            let contents = controller?.dropContents ?? .none
            controller?.hide()
            DispatchQueue.main.async { self?.committed(d, selection: sel, contents: contents) }
        }
        model.onMore = { [weak self, weak controller] sel, cat in
            controller?.hide()
            DispatchQueue.main.async { self?.openPicker(selection: sel, category: cat) }
        }
        model.onCancel = { [weak controller] in controller?.hide() }
        wheel = controller
        if showsWindows { controller.show(at: point, selection: selection) } else { model.show(selection: selection) }
    }

    public func openPicker(selection: Selection, category: OperationCategory = .convert) {
        picker?.close()
        let model = PickerModel(selection: selection, category: category, resolver: resolver(), gestures: settings.gestures)
        let controller = PickerWindowController(model: model)
        model.onCommit = { [weak self, weak controller] d, sel in
            controller?.close()
            self?.choose(d, selection: sel)
        }
        model.onCancel = { [weak controller] in controller?.close() }
        model.onShowWheel = { [weak self, weak controller] sel, cat in
            controller?.close()
            self?.openWheel(category: cat, at: NSEvent.mouseLocation, selection: sel, mode: .keyboard)
        }
        model.onChooseFiles = { [weak self, weak controller] in
            guard let self else { return }
            let urls = self.prompts.chooseFiles()
            guard !urls.isEmpty else { return }
            controller?.close()
            self.openPicker(selection: Selection(urls: urls), category: category)
        }
        picker = controller
        if showsWindows { controller.show() }
    }

    public func chooseFilesAndOpenPicker() {
        let urls = prompts.chooseFiles()
        guard !urls.isEmpty else { return }
        openPicker(selection: Selection(urls: urls))
    }

    /// ⌥⌘D: the Finder selection when Automation is allowed, otherwise the file chooser.
    public func openFinderSelection() {
        if !settings.automationConsent.contains("Finder") {
            switch prompts.confirmAutomation(app: "Finder", purpose: "DropForge can read which files are selected in Finder, so ⌥⌘D works on them directly.",
                                             fallback: "Choose Files Instead") {
            case .allow: settings.automationConsent.insert("Finder")
            case .useFallback: chooseFilesAndOpenPicker(); return
            case .cancel: return
            }
        }
        Task { @MainActor in
            switch await finder.selection() {
            case .files(let urls): openPicker(selection: Selection(urls: urls))
            case .nothingSelected:
                notice("Nothing is selected in Finder.")
                chooseFilesAndOpenPicker()
            case .denied:
                prompts.showMessage(title: "DropForge cannot see the Finder selection",
                                    text: "Permission to control Finder was declined. Choose the files instead, use Finder › Quick Actions › DropForge, or allow it in System Settings › Privacy & Security › Automation.",
                                    copyable: nil)
                lastNotice = "finder-denied"
                chooseFilesAndOpenPicker()
            case .unavailable(let why):
                notice("Finder selection unavailable: \(why)")
                chooseFilesAndOpenPicker()
            }
        }
    }

    // MARK: - Running a choice

    /// After a wheel drop: receive promised files first, if the drag carried promises.
    func committed(_ d: OperationDescriptor, selection: Selection, contents: DragContents) {
        guard case .promises(let receivers) = contents else {
            choose(d, selection: selection)
            return
        }
        let folder = DestinationResolver.fallbackDirectory.appendingPathComponent("Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let group = DispatchGroup()
        let collected = PromiseCollector()
        for r in receivers {
            group.enter()
            r.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                if error == nil { collected.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                let urls = collected.urls
                guard let self, !urls.isEmpty else { self?.notice("The dragged items could not be received."); return }
                self.choose(d, selection: Selection(urls: urls))
            }
        }
    }

    /// Entry point for a chosen operation from any chooser.
    public func choose(_ d: OperationDescriptor, selection: Selection) {
        switch d.kind {
        case .action(let action):
            perform(action, selection: selection)
        case .tool(.rename):
            openEditor(d, selection: selection)
        case .tool where d.needsEditor:
            openEditor(d, selection: selection)
        default:
            _ = run(d, selection: selection, parameters: .none)
        }
    }

    func openEditor(_ d: OperationDescriptor, selection: Selection) {
        let box = SelectionBox(selection)
        var controller: EditorWindowController?
        let context = EditorContext(selection: selection, descriptor: d, apply: { [weak self] params in
            guard let self else { return nil }
            let error = self.run(d, selection: box.value, parameters: params)
            if error == nil { controller?.finish() ; self.editors.removeAll { $0 === controller } }
            return error
        }, cancel: { [weak self] in
            controller?.finish()
            self?.editors.removeAll { $0 === controller }
        }, reorderHandler: { urls in
            box.value = Selection(items: urls.compactMap { u in box.value.items.first { $0.url == u } })
        })
        guard let view = EditorFactory.view(for: context) else {
            _ = run(d, selection: selection, parameters: .none)
            return
        }
        let c = EditorWindowController(title: d.title) { view }
        c.onClose = { [weak self, weak c] in self?.editors.removeAll { $0 === c } }
        controller = c
        editors.append(c)
        if showsWindows { c.show() }
    }

    /// Validates and starts a job. Returns a message when the parameters are not acceptable.
    @discardableResult
    public func run(_ d: OperationDescriptor, selection: Selection, parameters: ToolParameters) -> String? {
        do {
            try ParameterValidation.validate(parameters, selection: selection)
        } catch {
            return note(UserMessage.describe(error))
        }
        if case .rename(let pattern) = parameters {
            return renameNow(selection, pattern: pattern)
        }
        var excluded: Set<EngineRequirement> = []
        // Explain Automation before the first Apple Event to an iWork app.
        if let iWork = iWorkEngine(for: d, selection: selection), !settings.automationConsent.contains(iWork.rawValue) {
            let name = OfficeEngine.appName(iWork)
            let hasFallback = locator.availability().contains(.libreOffice)
            switch prompts.confirmAutomation(app: name, purpose: "\(name) will export “\(selection.items[0].url.lastPathComponent)” for you.",
                                             fallback: hasFallback ? "Use LibreOffice" : nil) {
            case .allow: settings.automationConsent.insert(iWork.rawValue)
            case .useFallback: excluded.insert(iWork)
            case .cancel: return note("Cancelled.")
            }
        }
        let resolver = resolver(excluding: excluded)
        if let reason = resolver.blockingReason(d, selection: selection) {
            return note(reason)
        }
        let plan = JobPlanner.plan(d, selection: selection, parameters: parameters)
        let executor = JobExecutor(performer: performer, resolver: resolver, location: settings.outputLocation)
        jobs.start(plan, executor: executor)
        lastNotice = nil
        return nil
    }

    func iWorkEngine(for d: OperationDescriptor, selection: Selection) -> EngineRequirement? {
        guard case .convert = d.kind, let item = selection.items.first else { return nil }
        let engine = resolver().engine(for: d, item: item)
        return [.keynote, .pages, .numbers].contains(engine) ? engine : nil
    }

    @discardableResult
    func note(_ message: String) -> String {
        lastNotice = message
        return message
    }

    func notice(_ message: String) {
        lastNotice = message
        if showsWindows { Toast.show(message) }
    }

    func renameNow(_ selection: Selection, pattern: RenamePattern) -> String? {
        do {
            let plan = try RenamePlanner.plan(selection.urls, pattern: pattern)
            let result = FileActions.rename(plan)
            let rows: [(String, UnitOutcome)] = result.done.map { ($0.lastPathComponent, .succeeded([$0], note: nil)) }
                + result.failures.map { ($0.0, .failed($0.1)) }
            jobs.record(title: "Rename", results: rows)
            return nil
        } catch {
            return note(UserMessage.describe(error))
        }
    }

    // MARK: - Actions (F04)

    public func perform(_ action: ActionKind, selection: Selection) {
        let urls = selection.urls
        switch action {
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                prompts.showMessage(title: "AirDrop is not available", text: "Turn on Wi-Fi and Bluetooth, or check AirDrop in Control Centre.", copyable: nil)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        case .float:
            shelf.add(urls)
        case .copyTo, .moveTo:
            guard let folder = prompts.chooseFolder(prompt: action == .copyTo ? "Copy Here" : "Move Here") else { return }
            let result = action == .copyTo ? FileActions.copy(urls, to: folder) : FileActions.move(urls, to: folder)
            let rows: [(String, UnitOutcome)] = result.done.map { ($0.lastPathComponent, .succeeded([$0], note: nil)) }
                + result.failures.map { ($0.0, .failed($0.1)) }
            jobs.record(title: action == .copyTo ? "Copy" : "Move", results: rows)
        case .copyPath:
            let text = urls.map(\.path).joined(separator: "\n")
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            notice(urls.count == 1 ? "Path copied" : "\(urls.count) paths copied")
        case .terminal, .iterm:
            let directory = selection.items.first.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() }
            guard let directory else { return }
            let app: URL? = action == .iterm ? locator.application(.iTerm)
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            guard let app else { prompts.showMessage(title: "Terminal app not found", text: "", copyable: nil); return }
            // Opening a folder with the terminal app starts a shell there; no Automation permission involved.
            NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Job completion

    func jobFinished(_ job: JobRecord) {
        if job.operationID == "tool.readQR", let file = job.outputs.first, let text = try? String(contentsOf: file, encoding: .utf8) {
            prompts.showMessage(title: "Found \(text.split(separator: "\n").count) code(s)", text: text, copyable: text)
        }
        if settings.revealWhenDone, !job.outputs.isEmpty, !job.wasCancelled, showsWindows {
            NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
        }
        if showsWindows { progress.scheduleAutoClose() }
    }

    // MARK: - Windows

    public func showSettings() { settingsWindow.show() }

    public func showWelcome() {
        let host = NSHostingController(rootView: WelcomeView(gestures: settings.gestures) { [weak self] in
            self?.settings.hasSeenWelcome = true
            self?.welcome?.close()
        })
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to DropForge"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        welcome = w
        if showsWindows {
            w.center()
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }
}

final class SelectionBox {
    var value: Selection
    init(_ value: Selection) { self.value = value }
}

final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func add(_ url: URL) { lock.withLock { list.append(url) } }
    var urls: [URL] { lock.withLock { list } }
}

/// Removes scratch folders left behind by a crash or forced quit.
public enum WorkspaceJanitor {
    public static func sweep(olderThan age: TimeInterval = 24 * 3600) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DropForge", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for e in entries {
            let date = (try? e.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(date) > age { try? FileManager.default.removeItem(at: e) }
        }
    }
}
