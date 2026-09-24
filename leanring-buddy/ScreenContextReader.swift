//
//  ScreenContextReader.swift
//  leanring-buddy
//
//  Exact text about what the user is doing, sent alongside the screenshot:
//  the app they're in, its window title and any text they've selected (read
//  through the Accessibility API YoClicky already has permission for), plus
//  the current date and time. Text is exact where a screenshot is blurry, so
//  "what does this mean?" about a selection gets the precise words.
//
//  Selected text and the window title can be turned off in Settings > AI.
//

import AppKit
import ApplicationServices

struct ScreenContext {
    let applicationName: String?
    let windowTitle: String?
    let selectedText: String?
    let selectedTextWasTruncated: Bool
}

enum ScreenContextReader {
    /// Accessibility calls are synchronous messages to the other app; don't
    /// let a frozen app hold up the question.
    private static let accessibilityTimeoutSeconds: Float = 0.5

    /// Reads the app name, focused window title and selected text of `application`.
    /// Call off the main thread.
    static func read(from application: NSRunningApplication, maxSelectedTextCharacters: Int) -> ScreenContext {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, accessibilityTimeoutSeconds)

        var windowTitle: String?
        if let focusedWindow = copyElementAttribute(applicationElement, kAXFocusedWindowAttribute) {
            windowTitle = copyStringAttribute(focusedWindow, kAXTitleAttribute)
        }

        var selectedText: String?
        var selectedTextWasTruncated = false
        if let focusedElement = copyElementAttribute(applicationElement, kAXFocusedUIElementAttribute),
           let fullSelectedText = copyStringAttribute(focusedElement, kAXSelectedTextAttribute) {
            selectedTextWasTruncated = fullSelectedText.count > maxSelectedTextCharacters
            selectedText = selectedTextWasTruncated ? String(fullSelectedText.prefix(maxSelectedTextCharacters)) : fullSelectedText
        }

        return ScreenContext(
            applicationName: application.localizedName,
            windowTitle: windowTitle,
            selectedText: selectedText,
            selectedTextWasTruncated: selectedTextWasTruncated
        )
    }

    /// e.g. "thursday 24 september 2026, 14:05 (Europe/Zurich)"
    static func currentDateDescription() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return "\(dateFormatter.string(from: Date()).lowercased()) (\(TimeZone.current.identifier))"
    }

    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let stringValue = value as? String else {
            return nil
        }
        let trimmedValue = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
