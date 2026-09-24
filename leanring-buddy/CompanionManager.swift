//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    /// True while the first-launch tour runs; shortcuts are ignored meanwhile.
    @Published private(set) var isOnboardingTourRunning: Bool = false

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Builds a client for the selected AI provider with the model and effort
    /// ResponseRouter picked for this question. Claude goes through the locally
    /// installed Claude Code CLI, logged in with the user's own Claude
    /// subscription (no proxy, no API key). See AIProvider.swift for other providers.
    private func makeAIClient(for responsePlan: ResponsePlan) -> AIProviderClient {
        selectedProvider.makeClient(model: responsePlan.modelAlias, effort: responsePlan.effort)
    }

    /// Speech uses the built-in macOS voices (no TTS key needed).
    private lazy var ttsClient: SystemTTSClient = {
        return SystemTTSClient()
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var dictationShortcutCancellable: AnyCancellable?
    /// Last app the user was in (not YoClicky), for reading its open document.
    private let frontmostApplicationTracker = FrontmostApplicationTracker()
    private var doubleTapControlCancellable: AnyCancellable?

    // MARK: - Text Chat

    /// Messages shown in the text chat window (double-tap control to toggle).
    @Published private(set) var textChatMessages: [TextChatMessage] = []
    private let textChatWindowManager = TextChatWindowManager()
    private let settingsWindowManager = SettingsWindowManager()

    func openSettings() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        settingsWindowManager.show(companionManager: self)
    }

    func toggleTextChat() {
        if !textChatWindowManager.isVisible {
            ClickySound.chatOpened.play()
        }
        textChatWindowManager.toggle(companionManager: self)
    }

    /// Clears the conversation shared by voice and text chat (Settings > Privacy).
    func clearConversationHistory() {
        clearTextChat()
    }

    /// Restores every preference to its default (Settings > General).
    func resetAllPreferences() {
        ClickySettings.resetAllPreferences()
        isCavemanMode = false
        selectedProvider = AIProviderSettings.selectedProvider
        selectedModel = AIProviderSettings.selectedModel(for: selectedProvider)
        setClickyCursorEnabled(true)
        prewarmAIClient()
    }

    func clearTextChat() {
        currentResponseTask?.cancel()
        textChatMessages = []
        conversationHistory = []
    }

    /// Sends a typed message through the same screenshot + Claude pipeline as
    /// voice, but shows the reply in the chat window instead of speaking it.
    func sendTextChatMessage(_ message: String) {
        textChatMessages.append(TextChatMessage(role: .user, text: message))
        ClickySound.messageSent.play()
        sendTranscriptToClaudeWithScreenshot(transcript: message, isFromTextChat: true)
    }

    /// Updates the in-progress assistant reply in the chat, hiding any partial [POINT...] tag.
    private func updatePendingTextChatReply(text: String, isPending: Bool, isError: Bool = false) {
        guard let pendingIndex = textChatMessages.lastIndex(where: { $0.role == .assistant && $0.isPending }) else { return }
        // Hide [REMEMBER: ...] and [POINT...] tags, including half-streamed ones.
        var visibleText = MemoryStore.extractRememberTags(from: text).cleanedText
        visibleText = visibleText.components(separatedBy: "[POINT").first ?? visibleText
        visibleText = visibleText.components(separatedBy: "[REMEMBER").first ?? visibleText
        textChatMessages[pendingIndex].text = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        textChatMessages[pendingIndex].isPending = isPending
        textChatMessages[pendingIndex].isError = isError
    }
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The AI provider used for responses. Persisted to UserDefaults.
    @Published private(set) var selectedProvider: AIProvider = AIProviderSettings.selectedProvider

    /// The model used for responses, per provider. Persisted to UserDefaults.
    @Published var selectedModel: String = AIProviderSettings.selectedModel(for: AIProviderSettings.selectedProvider)

    func setSelectedProvider(_ provider: AIProvider) {
        guard provider.isAvailable else { return }
        AIProviderSettings.selectedProvider = provider
        selectedProvider = provider
        selectedModel = AIProviderSettings.selectedModel(for: provider)
        prewarmAIClient()
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        AIProviderSettings.setSelectedModel(model, for: selectedProvider)
        prewarmAIClient()
    }

    /// Starts spare AI processes for the current model + style (with "Auto",
    /// one for Sonnet and one for Opus) so the next question skips the CLI's startup time.
    private func prewarmAIClient() {
        selectedProvider.prewarm(
            plans: ResponseRouter.plansToPrewarm(selectedModelID: selectedModel, useCavemanMode: isCavemanMode),
            systemPrompt: Self.composedSystemPrompt(useCavemanMode: isCavemanMode)
        )
    }

    /// Caveman mode trades detail for fewer tokens: short system prompt, terse
    /// answers, one smaller screenshot of the cursor screen, and shorter history.
    /// Persisted to UserDefaults.
    @Published var isCavemanMode: Bool = UserDefaults.standard.bool(forKey: "isCavemanMode")

    func setCavemanMode(_ enabled: Bool) {
        isCavemanMode = enabled
        UserDefaults.standard.set(enabled, forKey: "isCavemanMode")
        prewarmAIClient()
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }


    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        frontmostApplicationTracker.start()
        prewarmAIClient()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true


        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation, followed by the built-in tour
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the welcome animation and tour. Same flow as triggerOnboarding,
    /// but the cursor overlay is already visible.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        ClaudeCodeProcessPool.shared.shutdown()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        dictationShortcutCancellable?.cancel()
        doubleTapControlCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        dictationShortcutCancellable = globalPushToTalkShortcutMonitor
            .dictationShortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition, isDictation: true)
            }

        doubleTapControlCancellable = globalPushToTalkShortcutMonitor
            .textChatDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, !self.isOnboardingTourRunning else { return }
                self.toggleTextChat()
            }
    }

    /// - Parameter isDictation: true for the dictation shortcut, whose transcript is
    ///   typed into the focused text field instead of being sent to the AI.
    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition, isDictation: Bool = false) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !isOnboardingTourRunning else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Stop speech so the mic doesn't pick it up. Asking a new question also
            // cancels the previous answer; dictating leaves it alone.
            ttsClient.stopPlayback()
            if !isDictation {
                currentResponseTask?.cancel()
                clearDetectedElementLocation()
            }

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickySound.listeningStarted.play()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        if isDictation {
                            // Dictation: type it where the user's cursor is. No AI, no tokens.
                            DictationTextInserter.insert(finalTranscript)
                            return
                        }
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're yoclicky, a companion that lives in the user's menu bar. the user just asked you something with push-to-talk (or typed it in the chat window) and you can see their screen. your reply is usually spoken aloud by a text-to-speech voice, so write the way a sharp, friendly expert talks. this is an ongoing conversation, earlier exchanges are included when there are any.

    how to answer:
    - get it right first. read the screen carefully: exact labels, numbers, error messages, file names. base your answer on what's actually there, not on what's usually there.
    - lead with the answer in your first sentence. no preamble, don't restate the question.
    - match the length to the question. a quick fact or "where is it": one sentence. a how-to: the steps in order, in two to four sentences. a "why" or a concept: a clear explanation in three to five sentences, with one concrete example when it helps. if they ask for more detail, go as deep as they need.
    - be specific. name the exact button, menu, value or line you mean, like "the blue export button top right", not "the button".
    - for math, dates, times, money or units, work it out carefully and double-check the arithmetic before you answer. give the final result clearly.
    - the question comes from speech recognition and may contain misheard words. if something sounds odd, use the screen and the conversation to work out what they meant, and answer that.
    - if you're unsure or can't see something, say so in a few words and say what would help. never invent numbers, names, prices or facts. for things that change often, like prices, news or software versions, say your information may be out of date.
    - if the screenshot isn't relevant to the question, answer directly without mentioning it.
    - if a question is ambiguous, answer the most likely meaning. mention the other one only if it matters.
    - you can help with anything: coding, writing, studying, general knowledge, brainstorming.

    how it should sound:
    - all lowercase, casual and warm. no emojis. never say "simply" or "just".
    - write for the ear: plain sentences. no lists, bullet points, markdown, headings or asterisks.
    - say symbols as words: "for example" not "e.g.", "percent" not "%", "command shift four" not the key symbols. numbers can stay as digits.
    - don't read code out verbatim. describe what it does or what to change, and name the function or variable when that helps.
    - stop when the answer is complete. no filler like "hope that helps", and don't end with questions like "want me to explain more?". add one short next step only when it's genuinely useful.

    what you get:
    - one screenshot per screen. with several screens, the one labeled "primary focus" is where the cursor is, prioritize it but use the others if relevant.
    - often a sharp close-up of the area around the mouse cursor, for reading small text. use it to read, but never for pointing coordinates.
    - sometimes text context before the question: the app and window they're in, text they've selected (when there is some, the question is very likely about it), the date and time, facts you remember about them, or an open document.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the full screenshot images are labeled with their pixel dimensions (never use the close-up for coordinates). use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html is the markup that gives every web page its structure, the headings, paragraphs and links. the css file you have open is what styles it, colors, spacing and layout. [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    /// The companion prompt plus the user's language and custom instructions
    /// (Settings > Voice and Settings > AI).
    static func composedSystemPrompt(useCavemanMode: Bool) -> String {
        var systemPrompt = useCavemanMode ? cavemanVoiceResponseSystemPrompt : companionVoiceResponseSystemPrompt
        if let replyInstruction = ClickySettings.language.replyInstruction {
            systemPrompt += "\n\nlanguage: \(replyInstruction)"
        }
        if ClickySettings.memoryEnabled {
            systemPrompt += "\n\nmemory: when the user tells you something lasting about themselves that will help later (name, studies, job, preferences, ongoing projects), add [REMEMBER: short fact] right before any point tag. at most one per reply, only for genuinely lasting facts, never for what's on screen. if they ask you to remember something, always do it."
        }
        let customInstructions = ClickySettings.customInstructions
        if !customInstructions.isEmpty {
            systemPrompt += "\n\nthe user's own instructions (follow them unless they conflict with the rules above):\n\(customInstructions)"
        }
        return systemPrompt
    }

    /// The question plus optional context: remembered facts about the user and,
    /// when the question is about it, the text of the document open in the app
    /// they're using. Kept out of the system prompt so the warm spare process
    /// (keyed by system prompt) stays reusable.
    static func userPromptWithContext(
        question: String,
        documentApplication: NSRunningApplication?,
        useCavemanMode: Bool,
        isFromTextChat: Bool
    ) async -> String {
        var contextBlocks: [String] = []

        // Exact text about what the user is doing (Settings > AI > App context).
        if let documentApplication {
            var screenContextLines = ["right now: \(ScreenContextReader.currentDateDescription())"]
            if ClickySettings.appContextEnabled {
                let maxSelectedTextCharacters = useCavemanMode ? 2_000 : 8_000
                let screenContext = await Task.detached(priority: .userInitiated) {
                    ScreenContextReader.read(from: documentApplication, maxSelectedTextCharacters: maxSelectedTextCharacters)
                }.value
                if let applicationName = screenContext.applicationName {
                    screenContextLines.append("app in front: \(applicationName)")
                }
                if let windowTitle = screenContext.windowTitle {
                    screenContextLines.append("window title: \(windowTitle)")
                }
                if let selectedText = screenContext.selectedText {
                    let truncationNote = screenContext.selectedTextWasTruncated ? " (only the beginning, it's long)" : ""
                    screenContextLines.append("""
                    text the user has selected\(truncationNote):
                    <<<
                    \(selectedText)
                    >>>
                    """)
                }
            }
            contextBlocks.append(screenContextLines.joined(separator: "\n"))
        } else {
            contextBlocks.append("right now: \(ScreenContextReader.currentDateDescription())")
        }

        if ClickySettings.memoryEnabled, let memoryContext = MemoryStore.shared.promptContext {
            contextBlocks.append(memoryContext)
        }

        if ClickySettings.documentReadingEnabled,
           OpenDocumentReader.isQuestionAboutDocument(question),
           let documentApplication {
            let maxDocumentCharacters = useCavemanMode ? 12_000 : 40_000
            let openDocument = await Task.detached(priority: .userInitiated) {
                OpenDocumentReader.readOpenDocument(in: documentApplication, maxCharacters: maxDocumentCharacters)
            }.value
            if let openDocument {
                let truncationNote = openDocument.wasTruncated ? " (only the beginning, it's long)" : ""
                contextBlocks.append("""
                the user has "\(openDocument.fileName)" open in \(documentApplication.localizedName ?? "an app"). its full text\(truncationNote):
                <<<
                \(openDocument.text)
                >>>
                """)
            }
        }

        // Kept here rather than in the system prompt, so voice and chat share one warm process.
        let replyChannelNote = isFromTextChat
            ? "they typed this in the chat window, so your reply is shown as text, not spoken (still no markdown)"
            : "they said this out loud, so your reply will be spoken"
        return contextBlocks.joined(separator: "\n\n") + "\n\n(\(replyChannelNote))\nthe user's question: \(question)"
    }

    /// Token-saving variant of the companion prompt used in caveman mode.
    private static let cavemanVoiceResponseSystemPrompt = """
    you're yoclicky, voice companion. you see user's screen. reply is spoken aloud.
    talk like smart caveman: max one short sentence, fragments ok, no filler, no pleasantries, no questions back. drop articles. all lowercase, no emojis, no markdown, no symbols. keep technical words exact. only go longer if user asks to explain more.

    pointing: if showing a ui element helps, end with [POINT:x,y:label] using pixel coords of the screenshot (origin top-left, dimensions in image label), label 1-3 words. else end with [POINT:none].
    example: "color inspector, top right toolbar. click it. [POINT:1100,42:color inspector]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud with the macOS voice. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String, isFromTextChat: Bool = false) {
        pendingPrewarmTask?.cancel()
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        if isFromTextChat {
            // A newer message supersedes any reply still pending from a cancelled request
            for index in textChatMessages.indices where textChatMessages[index].isPending {
                textChatMessages[index].isPending = false
                if textChatMessages[index].text.isEmpty { textChatMessages[index].text = "(cancelled)" }
            }
            textChatMessages.append(TextChatMessage(role: .assistant, text: "", isPending: true))

            // Bring the cursor back transiently so it can point at things
            transientHideTask?.cancel()
            transientHideTask = nil
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
            clearDetectedElementLocation()
        }

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            let useCavemanMode = isCavemanMode
            // Model + effort for this question (Settings > AI > Model; "Auto" routes per question)
            let includesOpenDocument = ClickySettings.documentReadingEnabled
                && OpenDocumentReader.isQuestionAboutDocument(transcript)
            let responsePlan = ResponseRouter.plan(
                question: transcript,
                selectedModelID: selectedModel,
                useCavemanMode: useCavemanMode,
                includesOpenDocument: includesOpenDocument
            )
            print("🧭 Route: \(responsePlan.route.rawValue) → \(responsePlan.modelAlias), effort \(responsePlan.effort)")
            // Settings > AI > Screenshots. Caveman mode never sends more than the cursor screen.
            var screenshotMode = ClickySettings.screenshotMode
            if useCavemanMode && screenshotMode == .allScreens {
                screenshotMode = .cursorScreen
            }

            do {
                // Capture the screen(s) so the AI has context. Sonnet and Opus read
                // sharper screenshots (~3,000 image tokens each) than Haiku (~1,300);
                // caveman mode uses a smaller size to save tokens.
                let screenCaptures: [CompanionScreenCapture]
                var cursorCloseUpImageData: Data?
                if screenshotMode == .none {
                    screenCaptures = []
                } else {
                    // Plus a sharp close-up around the cursor for reading small text (~1,000 tokens).
                    async let closeUpCapture: Data? = useCavemanMode
                        ? nil
                        : try? CompanionScreenCaptureUtility.captureCursorCloseUpAsJPEG()
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
                        maxDimension: responsePlan.screenshotMaxLongEdge(useCavemanMode: useCavemanMode),
                        maxVisualTokens: responsePlan.maxVisualTokensPerImage,
                        onlyCursorScreen: screenshotMode == .cursorScreen
                    )
                    cursorCloseUpImageData = await closeUpCapture
                }

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                var labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }
                if let cursorCloseUpImageData {
                    labeledImages.append((
                        data: cursorCloseUpImageData,
                        label: "close-up of the area around the mouse cursor, sharper, for reading small text. not for [POINT] coordinates."
                    ))
                }

                // Pass conversation history so Claude remembers prior exchanges
                // (Settings > AI; caveman mode keeps at most 3 to save tokens)
                let historyLength = useCavemanMode ? min(3, ClickySettings.historyLength) : ClickySettings.historyLength
                let historyForAPI = conversationHistory.suffix(historyLength).map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let userPromptWithContext = await Self.userPromptWithContext(
                    question: transcript,
                    documentApplication: frontmostApplicationTracker.lastExternalApplication,
                    useCavemanMode: useCavemanMode,
                    isFromTextChat: isFromTextChat
                )
                guard !Task.isCancelled else { return }

                let (fullResponseText, _) = try await makeAIClient(for: responsePlan).analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.composedSystemPrompt(useCavemanMode: useCavemanMode),
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptWithContext,
                    onTextChunk: { [weak self] accumulatedText in
                        // Voice: no streaming text display — spinner stays until TTS plays.
                        // Text chat: stream the reply into the chat window.
                        guard isFromTextChat else { return }
                        self?.updatePendingTextChatReply(text: accumulatedText, isPending: true)
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                // Save any [REMEMBER: ...] facts, then parse the [POINT:...] tag
                let (responseTextWithoutMemoryTags, rememberedFacts) = MemoryStore.extractRememberTags(from: fullResponseText)
                if ClickySettings.memoryEnabled {
                    for rememberedFact in rememberedFacts {
                        MemoryStore.shared.add(rememberedFact)
                    }
                }
                let parseResult = Self.parsePointingCoordinates(from: responseTextWithoutMemoryTags)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")


                let isSpokenReplyOff = !isFromTextChat && !ClickySettings.speakReplies
                if isFromTextChat {
                    updatePendingTextChatReply(text: spokenText, isPending: false)
                    ClickySound.replyReceived.play()
                } else if isSpokenReplyOff {
                    // Settings > Voice > Speak replies is off: show the exchange in the chat window instead.
                    textChatMessages.append(TextChatMessage(role: .user, text: transcript))
                    textChatMessages.append(TextChatMessage(role: .assistant, text: spokenText))
                    if !textChatWindowManager.isVisible {
                        textChatWindowManager.show(companionManager: self)
                    }
                    ClickySound.replyReceived.play()
                } else if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await ttsClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        print("⚠️ TTS error: \(error)")
                        speakErrorFallback("I couldn't play the answer out loud.")
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                if isFromTextChat {
                    updatePendingTextChatReply(text: error.localizedDescription, isPending: false, isError: true)
                } else if let claudeCodeError = error as? ClaudeCodeError {
                    speakErrorFallback(claudeCodeError.spokenDescription)
                } else {
                    speakErrorFallback("I couldn't reach \(selectedProvider.displayName). Check that it's set up in YoClicky settings.")
                }
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
                prewarmAIClientWhenIdle()
            }
        }
    }

    private var pendingPrewarmTask: Task<Void, Never>?

    /// Refills the spare AI process only after speech has finished, so the
    /// CLI's startup CPU burst doesn't make the voice stutter.
    private func prewarmAIClientWhenIdle() {
        pendingPrewarmTask?.cancel()
        pendingPrewarmTask = Task {
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, voiceState == .idle else { return }
            prewarmAIClient()
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a short error message with the system voice so the user hears
    /// what went wrong (e.g. not logged in, usage limit reached).
    private func speakErrorFallback(_ utterance: String) {
        Task {
            try? await ttsClient.speakText(utterance)
        }
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Tour

    /// Built-in first-launch tour, started by BlueCursorView right after the
    /// "hey! i'm yoclicky" greeting: the cursor points at something on screen,
    /// then a tip bubble explains the shortcuts. (Replaces the original
    /// streamed intro video and music.)
    func startOnboardingTour() {
        isOnboardingTourRunning = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.performOnboardingDemoInteraction()
        }
        // Leave time for the pointing flight and its comment, then show the tip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
            self.isOnboardingTourRunning = false
            self.startOnboardingPromptStream()
        }
    }

    private func startOnboardingPromptStream() {
        var message = "hold \(ClickySettings.pushToTalkShortcut.displayText) and ask me anything"
        if ClickySettings.doubleTapKey != .off {
            message += ". double-tap \(ClickySettings.doubleTapKey.displayName) to type instead"
        }
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're yoclicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let onboardingPlan = ResponseRouter.plan(for: .standard, selectedModelID: selectedModel, useCavemanMode: false)
                let (fullResponseText, _) = try await makeAIClient(for: onboardingPlan).analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    conversationHistory: [],
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
