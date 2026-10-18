import AppKit
import ServiceManagement
import SwiftUI
import DropForgeCore
import DropForgeEngines

/// Automation (Apple Events) permission state for one app, checked without ever showing a prompt.
public enum AutomationStatus: Equatable, Sendable {
    case granted, denied, notAsked, appNotRunning, unknown(Int32)

    public var description: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Denied — change it in System Settings"
        case .notAsked: "Not asked yet (DropForge explains before asking)"
        case .appNotRunning: "Unknown until the app is open"
        case .unknown(let c): "Unknown (\(c))"
        }
    }

    @MainActor
    public static func check(bundleID: String) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown(-1) }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .appNotRunning
        default: return .unknown(status)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let locator: EngineLocator
    @State private var conflict: String?
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var automation: [(String, AutomationStatus)] = []

    var body: some View {
        TabView {
            gestures.tabItem { Label("Gestures", systemImage: "hand.draw") }
            output.tabItem { Label("Output", systemImage: "folder") }
            privacy.tabItem { Label("Privacy", systemImage: "lock.shield") }
            engines.tabItem { Label("Engines", systemImage: "gearshape.2") }
        }
        .padding(Tokens.Metrics.spacingL)
        .frame(width: 560, height: 470)
    }

    func modifierBinding(_ c: OperationCategory) -> Binding<Modifier?> {
        Binding(get: { settings.gestures.modifier(for: c) }, set: { m in
            if settings.setModifier(m, for: c) {
                conflict = nil
            } else {
                conflict = "\(m?.title ?? "That key") already opens another wheel. Pick a different key for one of them."
            }
        })
    }

    var gestures: some View {
        Form {
            Toggle("Open wheels while dragging files", isOn: $settings.dragGesturesEnabled)
            Text("While a file is being dragged from Finder or another app, tap a key to open a wheel at the pointer. Releasing the key keeps the wheel open until you drop.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(OperationCategory.allCases, id: \.self) { c in
                Picker("\(c.title) wheel", selection: modifierBinding(c)) {
                    ForEach(Modifier.allCases, id: \.self) { m in Text("\(m.symbol) \(m.title)").tag(Optional(m)) }
                    Text("Off").tag(Optional<Modifier>.none)
                }
                .disabled(!settings.dragGesturesEnabled)
            }
            if let conflict {
                Label(conflict, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.dfDanger).font(.callout)
            }
            Picker("Wheel size", selection: $settings.wheelSize) {
                ForEach(WheelSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("⌥⌘D opens DropForge for the files selected in Finder", isOn: $settings.hotKeyEnabled)
            Text("Without drag gestures you can always use the menu bar icon, drop files on it, or right-click files in Finder › Quick Actions / Services › DropForge.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    var output: some View {
        Form {
            Picker("Save results", selection: Binding(get: { settings.outputFolder == nil ? 0 : 1 }, set: { v in
                if v == 0 { settings.outputFolder = nil } else { chooseFolder() }
            })) {
                Text("Next to the original").tag(0)
                Text(settings.outputFolder.map { "In “\($0.lastPathComponent)”" } ?? "In a folder…").tag(1)
            }
            .pickerStyle(.radioGroup)
            if settings.outputFolder != nil { Button("Choose another folder…", action: chooseFolder) }
            Text("Originals are never replaced. If a name is taken, DropForge adds a number, e.g. “Photo 2.jpg”. When the original folder is read-only, results go to Downloads › DropForge.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show results in Finder when done", isOn: $settings.revealWhenDone)
            Picker("PDF page export resolution", selection: $settings.pdfExportDPI) {
                Text("150 DPI").tag(150.0); Text("300 DPI").tag(300.0); Text("600 DPI").tag(600.0)
            }
            Toggle("Open DropForge at login", isOn: Binding(get: { loginEnabled }, set: { setLogin($0) }))
            if let loginError { Text(loginError).font(.caption).foregroundStyle(Color.dfDanger) }
        }
        .formStyle(.grouped)
    }

    var privacy: some View {
        Form {
            Section("What DropForge does not do") {
                Label("No network access, accounts, analytics, uploads, limits or purchases.", systemImage: "wifi.slash")
                Label("Files are processed on this Mac only, by macOS and bundled open-source tools.", systemImage: "desktopcomputer")
            }
            Section("Permissions") {
                Label("Drag gestures need no permission: DropForge reads only the mouse button, modifier keys and the drag clipboard counter — never keystrokes.",
                      systemImage: "hand.raised")
                Label("Accessibility and Input Monitoring are not requested.", systemImage: "checkmark.shield")
                ForEach(automation, id: \.0) { name, status in
                    LabeledContent("Control \(name)", value: status.description)
                }
                Text("Automation is only needed to export with Keynote, Pages or Numbers, or to read the Finder selection for ⌥⌘D. DropForge explains this before macOS asks. If you decline, LibreOffice or the file chooser are used instead.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy & Security Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshAutomation)
    }

    var engines: some View {
        Form {
            ForEach(locator.report(), id: \.0) { engine, location in
                LabeledContent(engine.displayName) {
                    Text(location).font(.caption).foregroundStyle(location.contains("missing") || location.contains("not installed") ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Button("Third-party licences…") {
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) }
            }
        }
        .formStyle(.grouped)
    }

    func refreshAutomation() {
        var list: [(String, AutomationStatus)] = [("Finder", AutomationStatus.check(bundleID: "com.apple.finder"))]
        for e in [EngineRequirement.keynote, .pages, .numbers] where locator.application(e) != nil {
            if let id = EngineLocator.bundleIDs[e] { list.append((OfficeEngine.appName(e), AutomationStatus.check(bundleID: id))) }
        }
        automation = list
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { settings.outputFolder = url }
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS refused: \(error.localizedDescription)"
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
public final class SettingsWindowController {
    let settings: AppSettings
    let locator: EngineLocator
    private var window: NSWindow?

    public init(settings: AppSettings, locator: EngineLocator) {
        self.settings = settings
        self.locator = locator
    }

    public func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, locator: locator)))
            w.title = "DropForge Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let gestures: GestureSettings
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metrics.spacingM) {
            HStack(spacing: Tokens.Metrics.spacingM) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text("DropForge lives in the menu bar").font(.title2.weight(.semibold))
                    Text("Free, offline, no account.").foregroundStyle(.secondary)
                }
            }
            step("1", "Start dragging one or more files — from Finder or most apps.")
            step("2", "While dragging, tap \(gestures.convert?.symbol ?? "–") to convert, \(gestures.tools?.symbol ?? "–") for tools or \(gestures.actions?.symbol ?? "–") for actions. You can let go of the key.")
            step("3", "Drop on a segment. Results appear next to the original; nothing is overwritten.")
            Text("Prefer the keyboard? Use the menu bar icon › Choose Files…, right-click files › Quick Actions › DropForge, or press ⌥⌘D. Arrows choose, Return applies, Escape cancels.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Got it", action: onClose).keyboardShortcut(.defaultAction).tint(.dfAccent) }
        }
        .padding(Tokens.Metrics.spacingXL)
        .frame(width: 500)
    }

    func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Metrics.spacingS) {
            Text(n).font(.headline).frame(width: 24, height: 24).background(Circle().fill(Color.dfAccent.opacity(0.18)))
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
