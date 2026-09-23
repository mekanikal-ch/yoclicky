//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Hold-to-dictate shortcut (Settings > Shortcuts > Dictation).
    let dictationShortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    private var isDictationShortcutCurrentlyPressed = false

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    /// Fires when the user taps the configured modifier key (control by default)
    /// twice on its own, with no other keys or modifiers involved. Used to toggle
    /// the text chat window.
    let textChatDoubleTapPublisher = PassthroughSubject<Void, Never>()

    /// While true (e.g. the settings window is recording a new shortcut), no
    /// shortcut or double-tap events are published.
    var isPaused = false {
        didSet {
            isCurrentControlPressClean = false
            lastCleanControlTapTime = nil
        }
    }

    /// Max time the key can be held for a press to count as a tap, and max gap between two taps.
    private static let maxControlTapDuration: TimeInterval = 0.35
    private static let maxGapBetweenControlTaps: TimeInterval = 0.45

    // Double-tap state, mutated only from the event tap callback (main thread).
    private var controlKeyDownTime: Date?
    private var isCurrentControlPressClean = false
    private var lastCleanControlTapTime: Date?

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard !isPaused else {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        detectControlDoubleTap(eventType: eventType, keyCode: eventKeyCode, flags: event.flags)

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            // Only one of talk / dictate at a time.
            guard !isDictationShortcutCurrentlyPressed else { break }
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        let dictationTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isDictationShortcutCurrentlyPressed,
            shortcut: ClickySettings.dictationShortcut
        )

        switch dictationTransition {
        case .none:
            break
        case .pressed:
            guard !isShortcutCurrentlyPressed else { break }
            isDictationShortcutCurrentlyPressed = true
            dictationShortcutTransitionPublisher.send(.pressed)
        case .released:
            isDictationShortcutCurrentlyPressed = false
            dictationShortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Tracks lone taps of the configured double-tap key. A tap is "clean" when the
    /// key goes down with no other modifiers held and comes back up quickly with no
    /// other key or modifier pressed in between, so push-to-talk combos and
    /// ctrl + key style shortcuts never count as taps.
    private func detectControlDoubleTap(eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        let doubleTapKey = ClickySettings.doubleTapKey
        guard doubleTapKey != .off else { return }

        let allModifierFlags: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]
        let otherModifierFlags = allModifierFlags.subtracting(doubleTapKey.eventFlag)

        guard eventType == .flagsChanged, doubleTapKey.keyCodes.contains(keyCode) else {
            // Any other key or modifier change breaks the current tap sequence
            isCurrentControlPressClean = false
            lastCleanControlTapTime = nil
            return
        }

        let now = Date()

        if flags.contains(doubleTapKey.eventFlag) {
            // Key went down
            controlKeyDownTime = now
            isCurrentControlPressClean = flags.intersection(otherModifierFlags).isEmpty
            return
        }

        // Key went up
        defer { controlKeyDownTime = nil }
        guard isCurrentControlPressClean,
              let controlKeyDownTime,
              now.timeIntervalSince(controlKeyDownTime) <= Self.maxControlTapDuration else {
            lastCleanControlTapTime = nil
            return
        }

        if let lastCleanControlTapTime,
           now.timeIntervalSince(lastCleanControlTapTime) <= Self.maxGapBetweenControlTaps {
            self.lastCleanControlTapTime = nil
            textChatDoubleTapPublisher.send()
        } else {
            lastCleanControlTapTime = now
        }
    }
}
