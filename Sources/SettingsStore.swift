import Foundation
import Combine

// User settings, persisted via UserDefaults. Kept observable so SwiftUI
// settings UI and the dictation controller stay in sync.

struct ShortcutConfig: Codable, Equatable {
    var keyCode: UInt32        // CGKeyCode, e.g. 99 =_fn- on ANSI
    var requireCommand: Bool
    var requireOption: Bool
    var requireControl: Bool
    var requireShift: Bool

    static let `default` = ShortcutConfig(
        keyCode: 99, requireCommand: true, requireOption: false,
        requireControl: false, requireShift: false
    )
}

enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case whisperCPP = "whisper.cpp"
    case appleSpeech = "apple"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperCPP: return "whisper.cpp (local)"
        case .appleSpeech: return "Apple Speech (on-device)"
        }
    }
}

enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case ollama
    case openAICompatible = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .openAICompatible: return "OpenAI-compatible API"
        }
    }
}

/// Where on screen the notch pill anchors. Includes the three top-edge spots
/// plus the left/right screen edges (vertically centered) and a floating dock
/// hovering just above the bottom edge, Dock-style.
enum NotchPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight
    case leftCenter, rightCenter
    case bottomDock

    // Back-compat raw values for the originally shipped positions.
    static let left = NotchPosition.topLeft
    static let center = NotchPosition.topCenter
    static let right = NotchPosition.topRight

    var id: String { rawValue }

    /// Older launches persisted "left"/"center"/"right" — decode them onto
    /// the new case names so the setting survives the upgrade.
    init?(rawValue: String) {
        switch rawValue {
        case "left": self = .topLeft
        case "center": self = .topCenter
        case "right": self = .topRight
        case "topLeft": self = .topLeft
        case "topCenter": self = .topCenter
        case "topRight": self = .topRight
        case "leftCenter": self = .leftCenter
        case "rightCenter": self = .rightCenter
        case "bottomDock": self = .bottomDock
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .leftCenter: return "Left center"
        case .rightCenter: return "Right center"
        case .bottomDock: return "Floating dock"
        }
    }

    /// Vertical positions lay the pill out as a rotated (tall) pill instead of
    /// a wide one, so the content reads top-to-bottom along the screen edge.
    var isVertical: Bool {
        switch self {
        case .leftCenter, .rightCenter: return true
        default: return false
        }
    }
}

final class SettingsStore: ObservableObject {
    static let suiteName = "com.ankur.whisperwhy"

    @Published var hotkey: ShortcutConfig {
        didSet { persist() }
    }
    @Published var engine: TranscriptionEngine {
        didSet { persist() }
    }
    @Published var whisperModelPath: String {
        didSet { persist() }
    }
    @Published var language: String {
        didSet { persist() }
    }
    @Published var llmProvider: LLMProvider {
        didSet { persist() }
    }
    @Published var llmBaseURL: String {
        didSet { persist() }
    }
    @Published var llmModel: String {
        didSet { persist() }
    }
    @Published var llmAPIKey: String {
        didSet { persist() }
    }
    @Published var cleanupEnabled: Bool {
        didSet { persist() }
    }
    @Published var customCleanupPrompt: String {
        didSet { persist() }
    }
    // One term per line: "heard => replacement" or a bare preferred term.
    @Published var customTerms: String {
        didSet { persist() }
    }
    @Published var launchAtLogin: Bool {
        didSet { persist() }
    }
    /// Where the notch pill sits on the top edge. Default: top right.
    @Published var notchPosition: NotchPosition {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "hotkey": Self.encode(ShortcutConfig.default),
            "engine": TranscriptionEngine.whisperCPP.rawValue,
            "whisperModelPath": "",
            "language": "en",
            "llmProvider": LLMProvider.ollama.rawValue,
            "llmBaseURL": "http://localhost:11434/v1",
            "llmModel": "llama3.2:3b",
            "llmAPIKey": "",
            "cleanupEnabled": true,
            "customCleanupPrompt": "",
            "customTerms": "",
            "launchAtLogin": false,
            "notchPosition": NotchPosition.right.rawValue,
        ])
        hotkey = Self.decode(ShortcutConfig.self, defaults.object(forKey: "hotkey")) ?? .default
        engine = TranscriptionEngine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .whisperCPP
        whisperModelPath = defaults.string(forKey: "whisperModelPath") ?? ""
        language = defaults.string(forKey: "language") ?? "en"
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .ollama
        llmBaseURL = defaults.string(forKey: "llmBaseURL") ?? "http://localhost:11434/v1"
        llmModel = defaults.string(forKey: "llmModel") ?? "llama3.2:3b"
        llmAPIKey = defaults.string(forKey: "llmAPIKey") ?? ""
        cleanupEnabled = defaults.bool(forKey: "cleanupEnabled")
        customCleanupPrompt = defaults.string(forKey: "customCleanupPrompt") ?? ""
        customTerms = defaults.string(forKey: "customTerms") ?? ""
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        notchPosition = NotchPosition(rawValue: defaults.string(forKey: "notchPosition") ?? "") ?? .right
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(Self.encode(hotkey), forKey: "hotkey")
        d.set(engine.rawValue, forKey: "engine")
        d.set(whisperModelPath, forKey: "whisperModelPath")
        d.set(language, forKey: "language")
        d.set(llmProvider.rawValue, forKey: "llmProvider")
        d.set(llmBaseURL, forKey: "llmBaseURL")
        d.set(llmModel, forKey: "llmModel")
        d.set(llmAPIKey, forKey: "llmAPIKey")
        d.set(cleanupEnabled, forKey: "cleanupEnabled")
        d.set(customCleanupPrompt, forKey: "customCleanupPrompt")
        d.set(customTerms, forKey: "customTerms")
        d.set(launchAtLogin, forKey: "launchAtLogin")
        d.set(notchPosition.rawValue, forKey: "notchPosition")
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Any?) -> T? {
        guard let data = data as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
