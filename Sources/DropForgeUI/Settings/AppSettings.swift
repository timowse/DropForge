import AppKit
import Combine
import DropForgeCore

public enum WheelSize: String, CaseIterable, Codable, Sendable {
    case standard, large
    public var title: String { self == .standard ? "Standard" : "Large" }
}

/// Persistent preferences. Everything is local; nothing is synced or reported anywhere.
@MainActor
public final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published public var gestures: GestureSettings { didSet { save(gestures, "gestures") } }
    @Published public var dragGesturesEnabled: Bool { didSet { defaults.set(dragGesturesEnabled, forKey: "dragGesturesEnabled") } }
    @Published public var outputFolder: URL? { didSet { defaults.set(outputFolder?.path, forKey: "outputFolder") } }
    @Published public var revealWhenDone: Bool { didSet { defaults.set(revealWhenDone, forKey: "revealWhenDone") } }
    @Published public var wheelSize: WheelSize { didSet { defaults.set(wheelSize.rawValue, forKey: "wheelSize") } }
    @Published public var pdfExportDPI: Double { didSet { defaults.set(pdfExportDPI, forKey: "pdfExportDPI") } }
    @Published public var hotKeyEnabled: Bool { didSet { defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled") } }
    @Published public var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    /// Apps the user agreed to let DropForge control via Apple Events (asked before the first request).
    @Published public var automationConsent: Set<String> { didSet { defaults.set(Array(automationConsent), forKey: "automationConsent") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        gestures = Self.load(GestureSettings.self, "gestures", defaults) ?? .standard
        dragGesturesEnabled = defaults.object(forKey: "dragGesturesEnabled") as? Bool ?? true
        outputFolder = (defaults.string(forKey: "outputFolder")).map { URL(fileURLWithPath: $0, isDirectory: true) }
        revealWhenDone = defaults.object(forKey: "revealWhenDone") as? Bool ?? true
        wheelSize = WheelSize(rawValue: defaults.string(forKey: "wheelSize") ?? "") ?? .standard
        pdfExportDPI = defaults.object(forKey: "pdfExportDPI") as? Double ?? 300
        hotKeyEnabled = defaults.object(forKey: "hotKeyEnabled") as? Bool ?? true
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        automationConsent = Set(defaults.stringArray(forKey: "automationConsent") ?? [])
    }

    public var outputLocation: OutputLocation {
        outputFolder.map { .folder($0) } ?? .besideOriginal
    }

    /// Assigns a modifier, refusing combinations where two wheels share a key.
    @discardableResult
    public func setModifier(_ modifier: Modifier?, for category: OperationCategory) -> Bool {
        var candidate = gestures
        candidate.set(modifier, for: category)
        guard (try? candidate.validate()) != nil else { return false }
        gestures = candidate
        return true
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
