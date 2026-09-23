//
//  SettingsWindow.swift
//  leanring-buddy
//
//  Settings window opened from the gear button in the menu bar panel:
//  cursor color + visibility, and recordable keyboard shortcuts.
//

import AppKit
import Combine
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
        case ai
        case cursor
        case shortcuts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ai: return "AI"
            case .cursor: return "Appearance"
            case .shortcuts: return "Shortcuts"
            }
        }

        var systemImage: String {
            switch self {
            case .ai: return "sparkles"
            case .cursor: return "cursorarrow"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @ObservedObject var companionManager: CompanionManager
    @StateObject private var shortcutRecorder: ShortcutRecorder
    @State private var selectedPage: SettingsPage = .ai

    @AppStorage(ClickySettings.cursorColorKey) private var cursorColorHex = ClickySettings.defaultCursorColorHex
    @AppStorage(DS.Glass.windowOpacityKey) private var windowOpacity = DS.Glass.defaultWindowOpacity
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
                    case .ai:
                        aiSection
                    case .cursor:
                        cursorSection
                        windowSection
                    case .shortcuts:
                        shortcutsSection
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
                subtitle: "Only appears when you talk to it, chat, or it points at something."
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
                subtitle: "Less see-through makes text easier to read."
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
