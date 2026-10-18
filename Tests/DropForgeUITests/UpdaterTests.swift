import AppKit
import Testing
@testable import DropForgeUI

@Suite("Updater UI", .serialized)
@MainActor
struct UpdaterUITests {
    private func makeController() -> (StatusItemController, AppCoordinator, UserDefaults) {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "DropForgeUpdaterUITests")!
        defaults.removePersistentDomain(forName: "DropForgeUpdaterUITests")
        let coordinator = AppCoordinator(settings: AppSettings(defaults: defaults))
        coordinator.showsWindows = false
        return (StatusItemController(coordinator: coordinator), coordinator, defaults)
    }

    @Test("Menu exposes an accessible Check for Updates command")
    func updateMenuItem() {
        let (controller, _, defaults) = makeController()
        defer { defaults.removePersistentDomain(forName: "DropForgeUpdaterUITests") }
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let item = menu.items.first { $0.title == "Check for Updates…" }
        #expect(item != nil)
        #expect(item?.isEnabled == true)
    }

    @Test("Update command delegates without performing network access")
    func updateCallback() {
        let (controller, coordinator, defaults) = makeController()
        defer { defaults.removePersistentDomain(forName: "DropForgeUpdaterUITests") }
        var requested = false
        coordinator.checkForUpdates = { requested = true }
        controller.checkForUpdates()
        #expect(requested)
    }
}
