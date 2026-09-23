//
//  DictationTextInserter.swift
//  leanring-buddy
//
//  Types dictated text into whatever text field has focus, in any app, by
//  pasting it (Cmd+V) and then restoring the user's previous clipboard.
//  Pasting works across native, web and Electron apps, unlike setting the
//  focused element's text through the Accessibility API. Posting the key
//  events needs the Accessibility permission YoClicky already has.
//

import AppKit
import CoreGraphics

enum DictationTextInserter {
    /// Virtual key code of "V" (same position on QWERTY, AZERTY and QWERTZ).
    private static let vKeyCode: CGKeyCode = 9
    /// How long to wait before restoring the clipboard, so the paste has landed.
    private static let clipboardRestoreDelaySeconds = 0.6

    static func insert(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let savedClipboardItems = snapshotClipboard(pasteboard)

        pasteboard.clearContents()
        // Trailing space so consecutive dictations don't run together.
        pasteboard.setString(trimmedText + " ", forType: .string)
        let changeCountAfterOurWrite = pasteboard.changeCount

        postCommandV()
        print("⌨️ Dictation: inserted \(trimmedText.count) characters")

        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelaySeconds) {
            // Leave the clipboard alone if something else changed it meanwhile.
            guard pasteboard.changeCount == changeCountAfterOurWrite else { return }
            pasteboard.clearContents()
            if !savedClipboardItems.isEmpty {
                pasteboard.writeObjects(savedClipboardItems)
            }
        }
    }

    /// Copies every item and type on the clipboard so it can be put back.
    private static func snapshotClipboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { originalItem in
            let copiedItem = NSPasteboardItem()
            for itemType in originalItem.types {
                if let itemData = originalItem.data(forType: itemType) {
                    copiedItem.setData(itemData, forType: itemType)
                }
            }
            return copiedItem
        }
    }

    private static func postCommandV() {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: vKeyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: vKeyCode, keyDown: false)
        // Explicit flags, so modifiers still held from the dictation shortcut don't leak in.
        keyDownEvent?.flags = .maskCommand
        keyUpEvent?.flags = .maskCommand
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
}
