//
//  TextChatWindow.swift
//  leanring-buddy
//
//  Floating text chat with Clicky, toggled by double-tapping the control key.
//  Messages go through the same pipeline as voice (screenshot + Claude Code CLI
//  + pointing), but the reply is shown as text instead of spoken.
//

import AppKit
import SwiftUI

struct TextChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var isPending: Bool = false
    var isError: Bool = false
}

/// Titled panels can become key, but a borderless-looking chat still needs to
/// accept keyboard input while the app is an LSUIElement (no Dock icon).
private class TextChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class TextChatWindowManager {
    private var panel: NSPanel?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle(companionManager: CompanionManager) {
        if isVisible {
            hide()
        } else {
            show(companionManager: companionManager)
        }
    }

    func show(companionManager: CompanionManager) {
        let chatPanel = panel ?? makePanel(companionManager: companionManager)
        panel = chatPanel

        // Open on the screen the cursor is on, centered horizontally, lower third.
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        if let visibleFrame = targetScreen?.visibleFrame {
            let panelSize = chatPanel.frame.size
            chatPanel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.minY + visibleFrame.height * 0.2
            ))
        }

        NSApp.activate(ignoringOtherApps: true)
        chatPanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(companionManager: CompanionManager) -> NSPanel {
        let chatPanel = TextChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        chatPanel.title = "YoClicky"
        chatPanel.titlebarAppearsTransparent = true
        chatPanel.titleVisibility = .hidden
        chatPanel.isMovableByWindowBackground = true
        chatPanel.level = .floating
        chatPanel.isReleasedWhenClosed = false
        chatPanel.hidesOnDeactivate = false
        chatPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        chatPanel.makeTransparentForGlass()
        chatPanel.minSize = NSSize(width: 320, height: 260)

        let chatView = TextChatView(
            companionManager: companionManager,
            onClose: { [weak self] in self?.hide() }
        )
        chatPanel.contentView = GlassBackedContentView(rootView: chatView)
        return chatPanel
    }
}

struct TextChatView: View {
    @ObservedObject var companionManager: CompanionManager
    let onClose: () -> Void

    @State private var draftMessage = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(DS.Colors.borderSubtle)

            messageList

            Divider().background(DS.Colors.borderSubtle)

            inputRow
        }
        .background(Color.clear)
        .onAppear { isInputFocused = true }
        .onExitCommand { onClose() }
    }

    private var header: some View {
        HStack {
            Text("YoClicky")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(companionManager.isCavemanMode ? "caveman" : "normal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
            if !companionManager.textChatMessages.isEmpty {
                Button("Clear") { companionManager.clearTextChat() }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        // Leave room for the traffic-light buttons in the transparent title bar.
        .padding(.leading, 76)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(Color.clear)
    }

    private var messageList: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if companionManager.textChatMessages.isEmpty {
                        Text("ask about anything on your screen. press esc to close.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.top, 8)
                    }
                    ForEach(companionManager.textChatMessages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: companionManager.textChatMessages) { _, messages in
                if let lastMessageID = messages.last?.id {
                    scrollProxy.scrollTo(lastMessageID, anchor: .bottom)
                }
            }
        }
    }

    private func messageBubble(_ message: TextChatMessage) -> some View {
        let isUser = message.role == .user
        let displayText = message.isPending && message.text.isEmpty ? "thinking…" : message.text

        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(displayText)
                .font(.system(size: 13))
                .foregroundColor(isUser ? .white
                                 : message.isError ? DS.Colors.destructiveText
                                 : message.isPending && message.text.isEmpty ? DS.Colors.textTertiary
                                 : DS.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(
                    RoundedRectangle(cornerRadius: 16, style: .continuous),
                    tint: isUser ? DS.Glass.accentFill : nil
                )
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("message yoclicky…", text: $draftMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassBackground(Capsule())

            Button("Send", action: send)
                .buttonStyle(GlassProminentButtonStyle())
                .opacity(canSend ? 1 : 0.5)
                .disabled(!canSend)
        }
        .padding(12)
    }

    private var canSend: Bool {
        !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        draftMessage = ""
        companionManager.sendTextChatMessage(message)
        isInputFocused = true
    }
}
