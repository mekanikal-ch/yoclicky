//
//  ClickySettings.swift
//  leanring-buddy
//
//  User-configurable settings: cursor color, push-to-talk shortcut, and the
//  modifier key that is double-tapped to open the text chat. Everything is
//  persisted in UserDefaults as plain strings so SwiftUI views can observe the
//  values with @AppStorage.
//

import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Push-to-talk shortcut

/// A hold-to-talk shortcut: either modifiers only (e.g. ctrl + option) or
/// modifiers plus one regular key (e.g. ctrl + option + space).
struct PushToTalkShortcut: Codable, Equatable {
    var modifierFlagsRawValue: UInt
    /// nil for a modifier-only shortcut.
    var keyCode: UInt16?
    var keyLabel: String?

    static let `default` = PushToTalkShortcut(
        modifierFlagsRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue,
        keyCode: nil,
        keyLabel: nil
    )

    /// Default hold-to-dictate shortcut.
    static let defaultDictation = PushToTalkShortcut(
        modifierFlagsRawValue: NSEvent.ModifierFlags([.control, .shift]).rawValue,
        keyCode: nil,
        keyLabel: nil
    )

    static let supportedModifierFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue).intersection(Self.supportedModifierFlags)
    }

    var displayText: String {
        var parts = Self.modifierNames(for: modifierFlags)
        if let keyLabel { parts.append(keyLabel) }
        return parts.joined(separator: " + ")
    }

    static func modifierNames(for flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.function) { names.append("fn") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.command) { names.append("command") }
        return names
    }

    /// Human-readable label for a non-modifier key.
    static func keyLabel(for keyCode: UInt16, characters: String?) -> String {
        let specialKeyLabels: [UInt16: String] = [
            49: "space", 36: "return", 48: "tab", 51: "delete", 53: "esc",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let specialLabel = specialKeyLabels[keyCode] { return specialLabel }
        return (characters ?? "?").uppercased()
    }

    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
}

// MARK: - Double-tap key for the text chat

enum DoubleTapModifierKey: String, CaseIterable {
    case control
    case option
    case command
    case shift
    case function
    case off

    var displayName: String {
        switch self {
        case .control: return "control"
        case .option: return "option"
        case .command: return "command"
        case .shift: return "shift"
        case .function: return "fn"
        case .off: return "off"
        }
    }

    /// Left and right variants of the key.
    var keyCodes: Set<UInt16> {
        switch self {
        case .control: return [59, 62]
        case .option: return [58, 61]
        case .command: return [55, 54]
        case .shift: return [56, 60]
        case .function: return [63, 179]
        case .off: return []
        }
    }

    var eventFlag: CGEventFlags {
        switch self {
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .function: return .maskSecondaryFn
        case .off: return []
        }
    }

    static func from(keyCode: UInt16) -> DoubleTapModifierKey? {
        allCases.first { $0.keyCodes.contains(keyCode) }
    }
}

// MARK: - Storage

enum ClickySettings {
    static let cursorColorKey = "cursorColorHex"
    static let defaultCursorColorHex = "#3380FF"
    static let pushToTalkShortcutKey = "pushToTalkShortcut"
    static let doubleTapKeyKey = "textChatDoubleTapKey"
    static let dictationShortcutKey = "dictationShortcut"

    /// Cached so the global event tap doesn't decode JSON on every key event.
    private static var cachedPushToTalkShortcut: PushToTalkShortcut?
    private static var cachedDictationShortcut: PushToTalkShortcut?

    /// Hold to dictate into the focused text field (no AI involved).
    static var dictationShortcut: PushToTalkShortcut {
        get {
            if let cachedDictationShortcut { return cachedDictationShortcut }
            let storedShortcut = decodePushToTalkShortcut(
                UserDefaults.standard.string(forKey: dictationShortcutKey),
                fallback: .defaultDictation
            )
            cachedDictationShortcut = storedShortcut
            return storedShortcut
        }
        set {
            cachedDictationShortcut = newValue
            UserDefaults.standard.set(encodePushToTalkShortcut(newValue), forKey: dictationShortcutKey)
        }
    }

    static var pushToTalkShortcut: PushToTalkShortcut {
        get {
            if let cachedPushToTalkShortcut { return cachedPushToTalkShortcut }
            let storedShortcut = decodePushToTalkShortcut(UserDefaults.standard.string(forKey: pushToTalkShortcutKey))
            cachedPushToTalkShortcut = storedShortcut
            return storedShortcut
        }
        set {
            cachedPushToTalkShortcut = newValue
            UserDefaults.standard.set(encodePushToTalkShortcut(newValue), forKey: pushToTalkShortcutKey)
        }
    }

    static var doubleTapKey: DoubleTapModifierKey {
        get {
            UserDefaults.standard.string(forKey: doubleTapKeyKey).flatMap(DoubleTapModifierKey.init(rawValue:)) ?? .control
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: doubleTapKeyKey)
        }
    }

    static func decodePushToTalkShortcut(_ jsonString: String?, fallback: PushToTalkShortcut = .default) -> PushToTalkShortcut {
        guard let jsonData = jsonString?.data(using: .utf8),
              let decodedShortcut = try? JSONDecoder().decode(PushToTalkShortcut.self, from: jsonData) else {
            return fallback
        }
        return decodedShortcut
    }

    static func encodePushToTalkShortcut(_ shortcut: PushToTalkShortcut) -> String {
        guard let jsonData = try? JSONEncoder().encode(shortcut) else { return "" }
        return String(data: jsonData, encoding: .utf8) ?? ""
    }
}

extension Color {
    /// "#RRGGBB" in sRGB, for persisting colors picked in a ColorPicker.
    var hexString: String {
        guard let srgbColor = NSColor(self).usingColorSpace(.sRGB) else {
            return ClickySettings.defaultCursorColorHex
        }
        let red = Int((srgbColor.redComponent * 255).rounded())
        let green = Int((srgbColor.greenComponent * 255).rounded())
        let blue = Int((srgbColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

// MARK: - Language

/// Language for listening (speech recognition), speaking (voice) and replies.
enum AssistantLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case french
    case german
    case spanish
    case italian
    case portuguese
    case dutch
    case japanese
    case chinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Same as Mac"
        case .english: return "English"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .dutch: return "Nederlands"
        case .japanese: return "日本語"
        case .chinese: return "中文"
        }
    }

    var locale: Locale {
        switch self {
        case .system: return Locale.autoupdatingCurrent
        case .english: return Locale(identifier: "en-US")
        case .french: return Locale(identifier: "fr-FR")
        case .german: return Locale(identifier: "de-DE")
        case .spanish: return Locale(identifier: "es-ES")
        case .italian: return Locale(identifier: "it-IT")
        case .portuguese: return Locale(identifier: "pt-BR")
        case .dutch: return Locale(identifier: "nl-NL")
        case .japanese: return Locale(identifier: "ja-JP")
        case .chinese: return Locale(identifier: "zh-CN")
        }
    }

    /// Two-letter language code used to filter voices, e.g. "fr".
    var languageCode: String {
        locale.language.languageCode?.identifier ?? "en"
    }

    /// Instruction appended to the system prompt, or nil to leave replies in English.
    var replyInstruction: String? {
        switch self {
        case .system:
            guard languageCode != "en" else { return nil }
            let languageName = Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? languageCode
            return "always reply in \(languageName), whatever language the screen is in."
        case .english:
            return nil
        default:
            let languageName = Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? languageCode
            return "always reply in \(languageName), whatever language the screen is in."
        }
    }
}

// MARK: - Screenshots

enum ScreenshotMode: String, CaseIterable, Identifiable {
    case allScreens
    case cursorScreen
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allScreens: return "All screens"
        case .cursorScreen: return "Cursor screen"
        case .none: return "None"
        }
    }
}

// MARK: - Voice, AI and sound preferences

extension ClickySettings {
    static let languageKey = "assistantLanguage"
    static let ttsVoiceIdentifierKey = "ttsVoiceIdentifier"
    static let speechRateKey = "ttsSpeechRate"
    static let speakRepliesKey = "speakReplies"
    static let onDeviceRecognitionKey = "onDeviceSpeechRecognitionOnly"
    static let soundsEnabledKey = "soundsEnabled"
    static let customInstructionsKey = "customInstructions"
    static let screenshotModeKey = "screenshotMode"
    static let historyLengthKey = "conversationHistoryLength"
    static let documentReadingKey = "readOpenDocument"
    static let memoryEnabledKey = "memoryEnabled"
    static let appContextEnabledKey = "sendAppContext"

    static var documentReadingEnabled: Bool {
        UserDefaults.standard.object(forKey: documentReadingKey) as? Bool ?? true
    }

    static var memoryEnabled: Bool {
        UserDefaults.standard.object(forKey: memoryEnabledKey) as? Bool ?? true
    }

    /// Send the app's window title and any selected text with each question.
    static var appContextEnabled: Bool {
        UserDefaults.standard.object(forKey: appContextEnabledKey) as? Bool ?? true
    }

    /// AVSpeechUtterance rate. 0.5 is Apple's default, but it made voices like
    /// Ava rush the end of each word; 0.44 sounds natural.
    static let defaultSpeechRate = 0.44
    static let defaultHistoryLength = 10

    static var language: AssistantLanguage {
        UserDefaults.standard.string(forKey: languageKey).flatMap(AssistantLanguage.init(rawValue:)) ?? .system
    }

    static var speechRate: Double {
        UserDefaults.standard.object(forKey: speechRateKey) as? Double ?? defaultSpeechRate
    }

    static var speakReplies: Bool {
        UserDefaults.standard.object(forKey: speakRepliesKey) as? Bool ?? true
    }

    static var onDeviceRecognitionOnly: Bool {
        UserDefaults.standard.object(forKey: onDeviceRecognitionKey) as? Bool ?? true
    }

    static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: soundsEnabledKey) as? Bool ?? true
    }

    static var customInstructions: String {
        UserDefaults.standard.string(forKey: customInstructionsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var screenshotMode: ScreenshotMode {
        UserDefaults.standard.string(forKey: screenshotModeKey).flatMap(ScreenshotMode.init(rawValue:)) ?? .allScreens
    }

    static var historyLength: Int {
        UserDefaults.standard.object(forKey: historyLengthKey) as? Int ?? defaultHistoryLength
    }

    /// Every preference YoClicky stores (onboarding and permission state excluded).
    static let allPreferenceKeys = [
        cursorColorKey, pushToTalkShortcutKey, doubleTapKeyKey, DS.Glass.windowOpacityKey,
        languageKey, ttsVoiceIdentifierKey, speechRateKey, speakRepliesKey, onDeviceRecognitionKey,
        soundsEnabledKey, customInstructionsKey, screenshotModeKey, historyLengthKey,
        dictationShortcutKey, documentReadingKey, memoryEnabledKey, appContextEnabledKey,
        "isCavemanMode", "selectedClaudeModel", AIProviderSettings.selectedProviderKey, "isClickyCursorEnabled"
    ]

    static func resetAllPreferences() {
        for preferenceKey in allPreferenceKeys {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
        pushToTalkShortcut = .default
        dictationShortcut = .defaultDictation
    }
}

// MARK: - Sounds

/// Short built-in macOS sounds for chat and push-to-talk feedback.
enum ClickySound: String {
    case listeningStarted = "Tink"
    case chatOpened = "Pop"
    case messageSent = "Morse"
    case replyReceived = "Bottle"

    func play() {
        guard ClickySettings.soundsEnabled, let sound = NSSound(named: NSSound.Name(rawValue)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}
