import AppKit
import Combine
import DropForgeCore
import DropForgeEngines
import DropForgeUI
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: AppCoordinator!
    var statusItem: StatusItemController!
    var services: ServiceProvider!
    var updaterController: SPUStandardUpdaterController!
    var observers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let settings = AppSettings()
        coordinator = AppCoordinator(settings: settings)
        coordinator.checkForUpdates = { [weak self] in self?.updaterController.checkForUpdates(nil) }
        statusItem = StatusItemController(coordinator: coordinator)
        services = ServiceProvider(coordinator: coordinator)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.coordinator.settingsChanged() }
            .store(in: &observers)
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator.jobs.cancelAll()
        return .terminateNow
    }

    /// "Open With DropForge" and files dropped on the app icon in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        coordinator.openPicker(selection: Selection(urls: urls))
    }
}

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--smoke-test") {
    // Headless self-check of the installed bundle: generated fixtures only, in a fresh temp folder.
    let root = i + 1 < arguments.count ? URL(fileURLWithPath: arguments[i + 1]) : nil
    let code = SmokeTest.runBlocking(root: root)
    exit(code)
} else if let i = arguments.firstIndex(of: "--render-screens"), i + 1 < arguments.count {
    // Offscreen renders of every screen for visual review; fixtures go to a fresh temp folder.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let out = URL(fileURLWithPath: arguments[i + 1])
    Task { @MainActor in
        do {
            let fixtures = try FixtureFactory.makeTemporaryDirectory(prefix: "DropForgeGallery")
            let names = try await ScreenGallery.render(to: out, fixtures: fixtures)
            try? FileManager.default.removeItem(at: fixtures)
            print("rendered \(names.count) screens into \(out.path)")
            exit(0)
        } catch {
            print("render failed: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else if arguments.contains("--engine-report") {
    for (engine, location) in EngineLocator().report() { print("\(engine.displayName): \(location)") }
    exit(0)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
