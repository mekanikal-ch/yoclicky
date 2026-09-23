//
//  SettingsWindow.swift
//  leanring-buddy
//
//  Settings window opened from the gear button in the menu bar panel:
//  cursor color + visibility, and recordable keyboard shortcuts.
//

import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowManager {
    private var window: NSWindow?

    func show(companionManager: CompanionManager) {
        let settingsWindow = window ?? makeWindow(companionManager: companionManager)
        window = settingsWindow
        if !settingsWindow.isVisible {
            settingsWindow.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(companionManager: CompanionManager) -> NSWindow {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "YoClicky Settings"
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titleVisibility = .hidden
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.level = .floating
        settingsWindow.makeTransparentForGlass()
        settingsWindow.contentView = GlassBackedContentView(rootView: SettingsView(companionManager: companionManager))
        return settingsWindow
    }
}

// MARK: - Shortcut recording

/// Captures the next shortcut the user presses while the settings window is key.
/// The global push-to-talk monitor is paused meanwhile so recording a shortcut
/// doesn't also trigger it.
@MainActor
final class ShortcutRecorder: ObservableObject {
    enum Target {
        case pushToTalk
        case textChatDoubleTap
    }

    @Published private(set) var recordingTarget: Target?
    @Published private(set) var hintText: String?

    private let globalShortcutMonitor: GlobalPushToTalkShortcutMonitor
    private var localEventMonitor: Any?
    private var peakModifierFlags: NSEvent.ModifierFlags = []

    init(globalShortcutMonitor: GlobalPushToTalkShortcutMonitor) {
        self.globalShortcutMonitor = globalShortcutMonitor
    }

    func startRecording(_ target: Target) {
        stopRecording()
        recordingTarget = target
        peakModifierFlags = []
        hintText = target == .pushToTalk
            ? "hold your modifier keys and release, or press modifiers + a key. esc cancels."
            : "tap the modifier key to double-tap (control, option, command, shift or fn). esc cancels."
        globalShortcutMonitor.isPaused = true

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.handleRecordingEvent(event)
            return nil // swallow keys while recording
        }
    }

    func stopRecording() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        recordingTarget = nil
        hintText = nil
        globalShortcutMonitor.isPaused = false
    }

    private func handleRecordingEvent(_ event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection(PushToTalkShortcut.supportedModifierFlags)

        if event.type == .keyDown && event.keyCode == 53 && modifierFlags.isEmpty {
            stopRecording() // esc cancels
            return
        }

        switch recordingTarget {
        case .pushToTalk:
            recordPushToTalk(event: event, modifierFlags: modifierFlags)
        case .textChatDoubleTap:
            recordDoubleTapKey(event: event, modifierFlags: modifierFlags)
        case nil:
            break
        }
    }

    private func recordPushToTalk(event: NSEvent, modifierFlags: NSEvent.ModifierFlags) {
        if event.type == .keyDown {
            let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]
            var shortcutModifierFlags = modifierFlags
            // macOS sets the fn flag on its own for F-keys and arrow keys
            let isFunctionOrArrowKey = PushToTalkShortcut.functionKeyCodes.contains(event.keyCode)
                || arrowKeyCodes.contains(event.keyCode)
            if isFunctionOrArrowKey {
                shortcutModifierFlags.remove(.function)
            }

            guard !shortcutModifierFlags.isEmpty || PushToTalkShortcut.functionKeyCodes.contains(event.keyCode) else {
                hintText = "hold at least one modifier (control, option, command, shift, fn) with the key."
                return
            }

            ClickySettings.pushToTalkShortcut = PushToTalkShortcut(
                modifierFlagsRawValue: shortcutModifierFlags.rawValue,
                keyCode: event.keyCode,
                keyLabel: PushToTalkShortcut.keyLabel(for: event.keyCode, characters: event.charactersIgnoringModifiers)
            )
            stopRecording()
            return
        }

        guard event.type == .flagsChanged else { return }

        if !modifierFlags.isEmpty {
            peakModifierFlags.formUnion(modifierFlags)
            hintText = PushToTalkShortcut.modifierNames(for: peakModifierFlags).joined(separator: " + ")
                + " … release to save, or press a key"
            return
        }

        // All modifiers released: save a modifier-only shortcut if it has 2+ keys.
        // A single modifier would fire on every ordinary shortcut that uses it.
        guard !peakModifierFlags.isEmpty else { return }
        if PushToTalkShortcut.modifierNames(for: peakModifierFlags).count >= 2 {
            ClickySettings.pushToTalkShortcut = PushToTalkShortcut(
                modifierFlagsRawValue: peakModifierFlags.rawValue,
                keyCode: nil,
                keyLabel: nil
            )
            stopRecording()
        } else {
            hintText = "use two or more modifier keys, or a modifier plus a key."
            peakModifierFlags = []
        }
    }

    private func recordDoubleTapKey(event: NSEvent, modifierFlags: NSEvent.ModifierFlags) {
        if event.type == .flagsChanged,
           !modifierFlags.isEmpty,
           let doubleTapKey = DoubleTapModifierKey.from(keyCode: event.keyCode) {
            ClickySettings.doubleTapKey = doubleTapKey
            stopRecording()
            return
        }

        if event.type == .keyDown {
            hintText = "only modifier keys work for double-tap: control, option, command, shift or fn."
        }
    }
}

// MARK: - Settings view

struct SettingsView: View {
    enum SettingsPage: String, CaseIterable, Identifiable {
        case general
        case ai
        case voice
        case cursor
        case shortcuts
        case privacy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .ai: return "AI"
            case .voice: return "Voice"
            case .privacy: return "Privacy"
            case .cursor: return "Appearance"
            case .shortcuts: return "Shortcuts"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .ai: return "sparkles"
            case .voice: return "waveform"
            case .privacy: return "hand.raised"
            case .cursor: return "cursorarrow"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @ObservedObject var companionManager: CompanionManager
    @StateObject private var shortcutRecorder: ShortcutRecorder
    @State private var selectedPage: SettingsPage = .general

    enum ConnectionTestState {
        case idle
        case testing
        case succeeded(seconds: TimeInterval)
        case failed(message: String)
    }

    /// nil while loading; "" when the CLI wasn't found.
    @State private var claudeCodeVersion: String?
    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginErrorMessage: String?

    @AppStorage(ClickySettings.cursorColorKey) private var cursorColorHex = ClickySettings.defaultCursorColorHex
    @AppStorage(DS.Glass.windowOpacityKey) private var windowOpacity = DS.Glass.defaultWindowOpacity
    @AppStorage(ClickySettings.languageKey) private var languageRawValue = AssistantLanguage.system.rawValue
    @AppStorage(ClickySettings.ttsVoiceIdentifierKey) private var ttsVoiceIdentifier = ""
    @AppStorage(ClickySettings.speechRateKey) private var speechRate = ClickySettings.defaultSpeechRate
    @AppStorage(ClickySettings.speakRepliesKey) private var speakReplies = true
    @AppStorage(ClickySettings.onDeviceRecognitionKey) private var onDeviceRecognitionOnly = true
    @AppStorage(ClickySettings.soundsEnabledKey) private var soundsEnabled = true
    @AppStorage(ClickySettings.customInstructionsKey) private var customInstructions = ""
    @AppStorage(ClickySettings.screenshotModeKey) private var screenshotModeRawValue = ScreenshotMode.allScreens.rawValue
    @AppStorage(ClickySettings.historyLengthKey) private var historyLength = ClickySettings.defaultHistoryLength

    @State private var voicePreviewSpeaker = SystemTTSClient()
    @State private var isShowingResetConfirmation = false
    @State private var historyClearedMessageVisible = false
    @AppStorage(ClickySettings.pushToTalkShortcutKey) private var pushToTalkShortcutJSON = ""
    @AppStorage(ClickySettings.doubleTapKeyKey) private var doubleTapKeyRawValue = DoubleTapModifierKey.control.rawValue

    private static let presetCursorColorHexes = ["#3380FF", "#8F46EB", "#E84D9E", "#FF8C33", "#34D399", "#E5484D", "#ECEEED"]

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _shortcutRecorder = StateObject(wrappedValue: ShortcutRecorder(
            globalShortcutMonitor: companionManager.globalPushToTalkShortcutMonitor
        ))
    }

    private var cursorColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: cursorColorHex) },
            set: { cursorColorHex = $0.hexString }
        )
    }

    private var pushToTalkShortcut: PushToTalkShortcut {
        ClickySettings.decodePushToTalkShortcut(pushToTalkShortcutJSON)
    }

    private var doubleTapKey: DoubleTapModifierKey {
        DoubleTapModifierKey(rawValue: doubleTapKeyRawValue) ?? .control
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .padding(8)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(selectedPage.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)

                    switch selectedPage {
                    case .general:
                        generalSection
                    case .ai:
                        claudeCodeStatusSection
                        aiSection
                        responsesSection
                        customInstructionsSection
                    case .voice:
                        voiceSection
                    case .cursor:
                        cursorSection
                        windowSection
                    case .shortcuts:
                        shortcutsSection
                    case .privacy:
                        privacySection
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Keep scrolling content out from under the (hidden) title bar.
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 460)
        .onChange(of: selectedPage) { _, _ in shortcutRecorder.stopRecording() }
        .onDisappear { shortcutRecorder.stopRecording() }
    }

    // MARK: Sidebar

    /// Floating glass sidebar (Tahoe style). The window's close/minimize buttons
    /// sit in its top area, so the items start below them.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                let isSelected = page == selectedPage
                Button(action: { selectedPage = page }) {
                    HStack(spacing: 8) {
                        Image(systemName: page.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(page.title)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(isSelected ? .white : DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? DS.Glass.accentFill : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 44)
        .padding(.bottom, 10)
        .frame(width: 180)
        .frame(maxHeight: .infinity)
        .glassCard(cornerRadius: 14)
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection(title: "STARTUP") {
                settingsRow(title: "Launch at login", subtitle: isLaunchAtLoginEnabled
                    ? "On: YoClicky starts automatically when you log in."
                    : "Off: open YoClicky yourself from Applications.") {
                    Toggle("", isOn: Binding(
                        get: { isLaunchAtLoginEnabled },
                        set: { setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                if let launchAtLoginErrorMessage {
                    Text(launchAtLoginErrorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.destructiveText)
                }
            }

            settingsSection(title: "SOUNDS") {
                settingsRow(title: "Sound effects", subtitle: soundsEnabled
                    ? "On: soft sounds when listening starts and for chat messages."
                    : "Off: YoClicky stays silent except for spoken answers.") {
                    Toggle("", isOn: $soundsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            settingsSection(title: "TROUBLESHOOTING") {
                settingsRow(title: "Logs", subtitle: "What YoClicky did and any errors, in ~/Library/Logs/YoClicky.") {
                    HStack(spacing: 8) {
                        Button("Open Logs") { AppLogFile.openInViewer() }
                            .buttonStyle(GlassButtonStyle())
                        Button("Show in Finder") { AppLogFile.revealInFinder() }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
                settingsRow(title: "Reset all settings", subtitle: "Colors, shortcuts, voice, AI and appearance go back to defaults.") {
                    Button("Reset…") { isShowingResetConfirmation = true }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            .alert("Reset all settings?", isPresented: $isShowingResetConfirmation) {
                Button("Reset", role: .destructive) { companionManager.resetAllPreferences() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your conversation and permissions are kept.")
            }
        }
    }

    private func setLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginErrorMessage = nil
        } catch {
            launchAtLoginErrorMessage = "Couldn't change this: \(error.localizedDescription)"
        }
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: Claude Code status

    private var claudeCodeStatusSection: some View {
        settingsSection(title: "CLAUDE CODE") {
            settingsRow(title: "Installed", subtitle: claudeCodeInstallSubtitle) {
                Image(systemName: claudeCodeVersion == nil ? "hourglass"
                      : claudeCodeVersion!.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(claudeCodeVersion == nil ? DS.Colors.textTertiary
                                     : claudeCodeVersion!.isEmpty ? DS.Colors.destructiveText : DS.Colors.success)
            }

            settingsRow(title: "Connection", subtitle: connectionTestSubtitle) {
                Button(action: runConnectionTest) {
                    if case .testing = connectionTestState {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .buttonStyle(GlassProminentButtonStyle())
                .disabled({ if case .testing = connectionTestState { return true } else { return false } }())
            }
        }
        .task {
            let installedVersion = await ClaudeCodeCLI.installedVersion()
            claudeCodeVersion = installedVersion ?? ""
        }
    }

    private var claudeCodeInstallSubtitle: String {
        guard let claudeCodeVersion else { return "Checking…" }
        guard !claudeCodeVersion.isEmpty else {
            return "Not found. Install Claude Code, then run `claude` in Terminal to log in."
        }
        let installPath = ClaudeCodeCLI.locateClaudeExecutable() ?? ""
        return "\(claudeCodeVersion) at \(installPath)"
    }

    private var connectionTestSubtitle: String {
        switch connectionTestState {
        case .idle:
            return "Sends a tiny test message with Haiku to check your login works."
        case .testing:
            return "Testing…"
        case .succeeded(let seconds):
            return "✓ Connected with your Claude subscription, answered in \(String(format: "%.1f", seconds))s."
        case .failed(let message):
            return "✗ \(message)"
        }
    }

    private func runConnectionTest() {
        connectionTestState = .testing
        Task {
            do {
                let roundTripSeconds = try await ClaudeCodeCLI.testConnection()
                connectionTestState = .succeeded(seconds: roundTripSeconds)
            } catch {
                connectionTestState = .failed(message: error.localizedDescription)
            }
        }
    }

    // MARK: AI

    private var aiSection: some View {
        settingsSection(title: "PROVIDER") {
            ForEach(AIProvider.allCases) { provider in
                let isSelected = provider == companionManager.selectedProvider
                Button(action: { companionManager.setSelectedProvider(provider) }) {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13))
                            .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(provider.isAvailable ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                            Text(provider.connectionDescription)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        Spacer()
                        if !provider.isAvailable {
                            Text("coming soon")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(DS.Glass.subtleFill))
                                .overlay(Capsule().stroke(DS.Glass.hairline, lineWidth: 0.5))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!provider.isAvailable)
                .pointerCursor(isEnabled: provider.isAvailable)
            }
        }
    }

    // MARK: Cursor

    private var cursorSection: some View {
        settingsSection(title: "CURSOR") {
            HStack(spacing: 12) {
                Triangle()
                    .fill(Color(hex: cursorColorHex))
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-35))
                    .shadow(color: Color(hex: cursorColorHex).opacity(0.6), radius: 6)
                    .frame(width: 28)

                ColorPicker("Color", selection: cursorColorBinding, supportsOpacity: false)
                    .labelsHidden()

                ForEach(Self.presetCursorColorHexes, id: \.self) { presetHex in
                    Button(action: { cursorColorHex = presetHex }) {
                        Circle()
                            .fill(Color(hex: presetHex))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().stroke(
                                    DS.Colors.textPrimary,
                                    lineWidth: cursorColorHex.uppercased() == presetHex ? 2 : 0
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            settingsRow(
                title: "Hide cursor until needed",
                subtitle: companionManager.isClickyCursorEnabled
                    ? "Off: the cursor always follows your mouse."
                    : "On: the cursor only appears when you talk to it, chat, or it points at something."
            ) {
                Toggle("", isOn: Binding(
                    get: { !companionManager.isClickyCursorEnabled },
                    set: { companionManager.setClickyCursorEnabled(!$0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
            }
        }
    }

    // MARK: Windows

    private var windowSection: some View {
        settingsSection(title: "WINDOWS") {
            settingsRow(
                title: "Window opacity",
                subtitle: "\(Int((windowOpacity * 100).rounded()))%: \(windowOpacity < 0.4 ? "very glassy, text can be harder to read" : windowOpacity > 0.85 ? "almost solid, easiest to read" : "glassy with readable text")."
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dotted")
                        .foregroundColor(DS.Colors.textTertiary)
                    Slider(value: $windowOpacity, in: 0...1)
                        .frame(width: 140)
                    Image(systemName: "circle.fill")
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        settingsSection(title: "KEYBOARD") {
            settingsRow(title: "Push to talk", subtitle: "Hold to speak to YoClicky.") {
                shortcutButton(
                    label: pushToTalkShortcut.displayText,
                    target: .pushToTalk,
                    onReset: { ClickySettings.pushToTalkShortcut = .default }
                )
            }

            settingsRow(title: "Text chat", subtitle: "Double-tap this key to open or close the chat.") {
                HStack(spacing: 6) {
                    shortcutButton(
                        label: doubleTapKey == .off ? "off" : "\(doubleTapKey.displayName) × 2",
                        target: .textChatDoubleTap,
                        onReset: { ClickySettings.doubleTapKey = .control }
                    )
                    Menu {
                        ForEach(DoubleTapModifierKey.allCases, id: \.self) { key in
                            Button(key.displayName) { ClickySettings.doubleTapKey = key }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                }
            }

            if let hintText = shortcutRecorder.hintText {
                Text(hintText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accentText)
            }
        }
    }

    private func shortcutButton(label: String, target: ShortcutRecorder.Target, onReset: @escaping () -> Void) -> some View {
        let isRecording = shortcutRecorder.recordingTarget == target
        return HStack(spacing: 6) {
            Button(action: {
                if isRecording {
                    shortcutRecorder.stopRecording()
                } else {
                    shortcutRecorder.startRecording(target)
                }
            }) {
                Text(isRecording ? "press keys…" : label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isRecording ? DS.Colors.accentText : DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(minWidth: 110)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isRecording ? AnyShapeStyle(Color.white) : AnyShapeStyle(DS.Glass.subtleFill))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isRecording ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Click, then press the new shortcut")

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Reset to default")
        }
    }

    // MARK: AI responses

    private var responsesSection: some View {
        settingsSection(title: "RESPONSES") {
            settingsRow(title: "Model", subtitle: modelDescription) {
                GlassSegmentedControl {
                    ForEach(companionManager.selectedProvider.modelOptions) { modelOption in
                        GlassSegment(
                            label: modelOption.label,
                            isSelected: companionManager.selectedModel == modelOption.modelID,
                            action: { companionManager.setSelectedModel(modelOption.modelID) }
                        )
                    }
                }
            }
            settingsRow(title: "Style", subtitle: companionManager.isCavemanMode
                ? "Caveman: one-line answers, a smaller screenshot of the cursor screen only and the last 3 exchanges. About half the tokens."
                : "Normal: friendly one-to-two sentence answers, going deeper when you ask.") {
                GlassSegmentedControl {
                    GlassSegment(label: "Normal", isSelected: !companionManager.isCavemanMode,
                                 action: { companionManager.setCavemanMode(false) })
                    GlassSegment(label: "Caveman", isSelected: companionManager.isCavemanMode,
                                 action: { companionManager.setCavemanMode(true) })
                }
            }
            settingsRow(title: "Screenshots", subtitle: screenshotDescription) {
                GlassSegmentedControl {
                    ForEach(ScreenshotMode.allCases) { screenshotMode in
                        GlassSegment(
                            label: screenshotMode.displayName,
                            isSelected: screenshotModeRawValue == screenshotMode.rawValue,
                            action: { screenshotModeRawValue = screenshotMode.rawValue }
                        )
                    }
                }
            }
            settingsRow(title: "Conversation memory", subtitle: historyLength == 0
                ? "Each question starts fresh; nothing earlier is sent."
                : "Sends your last \(historyLength) exchange\(historyLength == 1 ? "" : "s") so YoClicky keeps the context. Fewer saves tokens.") {
                Stepper(value: $historyLength, in: 0...10) {
                    Text("\(historyLength)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(minWidth: 20, alignment: .trailing)
                }
            }
        }
    }

    private var modelDescription: String {
        let selectedModelID = companionManager.selectedModel.lowercased()
        if selectedModelID.contains("haiku") {
            return "Haiku: fastest and uses the least of your plan. Great for \"where is…\" questions."
        }
        if selectedModelID.contains("opus") {
            return "Opus: smartest but slowest, and uses up your plan fastest."
        }
        return "Sonnet: balanced, smart and fairly fast. A good default."
    }

    private var screenshotDescription: String {
        switch ScreenshotMode(rawValue: screenshotModeRawValue) ?? .allScreens {
        case .allScreens:
            return "All screens: YoClicky sees every monitor (about 1,400 tokens each)."
        case .cursorScreen:
            return "Cursor screen: only the screen your mouse is on. Cheaper with several monitors."
        case .none:
            return "None: cheapest, but YoClicky can't see your screen or point at things."
        }
    }

    private var customInstructionsSection: some View {
        settingsSection(title: "CUSTOM INSTRUCTIONS") {
            Text("Told to YoClicky with every question, for example \"I'm an ETH student, keep answers short and explain like a tutor.\"")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            TextEditor(text: $customInstructions)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 90)
                .glassCard(cornerRadius: 10)
        }
    }

    // MARK: Voice

    private var selectedLanguage: AssistantLanguage {
        AssistantLanguage(rawValue: languageRawValue) ?? .system
    }

    private var voiceSection: some View {
        let languageVoices = SystemTTSClient.availableVoices(for: selectedLanguage)
        let currentVoice = SystemTTSClient.selectedVoice()

        return VStack(alignment: .leading, spacing: 20) {
            settingsSection(title: "LANGUAGE") {
                settingsRow(title: "Language", subtitle: "YoClicky listens, speaks and replies in \(selectedLanguage == .system ? "your Mac's language" : selectedLanguage.displayName).") {
                    Picker("", selection: $languageRawValue) {
                        ForEach(AssistantLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: languageRawValue) { _, _ in ttsVoiceIdentifier = "" }
                }
            }

            settingsSection(title: "SPEAKING") {
                settingsRow(title: "Speak replies", subtitle: speakReplies
                    ? "On: voice answers are read aloud."
                    : "Off: voice answers appear in the chat window instead of being read aloud.") {
                    Toggle("", isOn: $speakReplies)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                settingsRow(title: "Voice", subtitle: "Download better voices in System Settings > Accessibility > Spoken Content.") {
                    HStack(spacing: 8) {
                        Picker("", selection: $ttsVoiceIdentifier) {
                            Text("Best available").tag("")
                            ForEach(languageVoices, id: \.identifier) { voice in
                                Text(voiceMenuLabel(voice)).tag(voice.identifier)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)

                        Button(action: { voicePreviewSpeaker.speakPreview(voice: SystemTTSClient.selectedVoice()) }) {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(GlassButtonStyle())
                        .help("Preview \(currentVoice?.name ?? "voice")")
                    }
                }
                settingsRow(title: "Speed", subtitle: speechRate < 0.45 ? "Slower than normal." : speechRate > 0.55 ? "Faster than normal." : "Normal speed.") {
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise.fill")
                            .foregroundColor(DS.Colors.textTertiary)
                        Slider(value: $speechRate, in: 0.35...0.65)
                            .frame(width: 140)
                        Image(systemName: "hare.fill")
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            settingsSection(title: "LISTENING") {
                settingsRow(title: "On-device recognition", subtitle: onDeviceRecognitionOnly
                    ? "On: your voice never leaves this Mac."
                    : "Off: Apple's servers transcribe your voice, which can be more accurate.") {
                    Toggle("", isOn: $onDeviceRecognitionOnly)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    private func voiceMenuLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name) (Premium)"
        case .enhanced: return "\(voice.name) (Enhanced)"
        default: return voice.name
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection(title: "WHAT GETS SENT") {
                VStack(alignment: .leading, spacing: 8) {
                    privacyLine("keyboard", "Only when you hold the talk shortcut or send a chat message. Nothing runs in the background.")
                    privacyLine("waveform", "Your voice is turned into text by Apple speech recognition, on this Mac when on-device is on.")
                    privacyLine("photo", "A screenshot (per Settings > AI > Screenshots) and your text go to Claude through Claude Code, using your Claude account.")
                    privacyLine("externaldrive", "Screenshots aren't saved. Settings and the current conversation stay on this Mac only.")
                    privacyLine("eye.slash", "No analytics, no tracking, no YoClicky servers.")
                }
                .glassCard()
            }

            settingsSection(title: "CONVERSATION") {
                settingsRow(title: "Clear conversation", subtitle: "Forget earlier questions and answers, in voice and chat.") {
                    Button(historyClearedMessageVisible ? "Cleared" : "Clear") {
                        companionManager.clearConversationHistory()
                        historyClearedMessageVisible = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { historyClearedMessageVisible = false }
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
        }
    }

    private func privacyLine(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: Layout helpers

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            content()
        }
    }

    private func settingsRow<Accessory: View>(title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            accessory()
        }
    }
}
