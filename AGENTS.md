# YoClicky - Agent Instructions

<!-- Single source of truth for AI coding agents. CLAUDE.md is a symlink to this file. -->

## Overview

macOS menu bar companion app (`LSUIElement`, no Dock icon or main window). The user holds a push-to-talk shortcut (default `control + option`), speaks, and YoClicky sends the transcript plus a screenshot to Claude through the locally installed **Claude Code CLI** (`claude -p`), which is logged in with the user's own Claude subscription. The reply is spoken with a macOS voice, and a cursor overlay can fly to and point at UI elements Claude references.

There is no server: no API keys, no proxy, no analytics. Everything runs on the user's Mac except the Claude request itself.

## Architecture

- **Framework**: SwiftUI with AppKit bridging (`NSPanel`/`NSWindow` via `NSHostingView`) for the menu bar panel, overlay, chat and settings windows
- **AI**: `ClaudeCodeCLI` runs `claude -p` with stream-json input/output, `--model <alias>` (`haiku`/`sonnet`/`opus`, always the newest of each family) and `--effort`, no tools, no settings/MCP, no session persistence. Up to two spare processes (one per model + effort) are pre-started (`ClaudeCodeProcessPool`) once speech has finished, so requests skip CLI startup. 60s inactivity timeout, one retry for transient errors, classified errors (`ClaudeCodeError`)
- **Routing**: `ResponseRouter` picks model, effort and screenshot size per question. "Auto" (default) uses Sonnet for everyday questions and Opus for math, numbers, code and "why" questions (Opus was far more reliable at mental arithmetic), with `xhigh` effort when the user asks for depth or about the open document
- **Providers**: `AIProvider` lists Claude (working) and other AIs marked "coming soon"; new ones implement `AIProviderClient`
- **Speech-to-text**: Apple `SFSpeechRecognizer` (`AppleSpeechTranscriptionProvider`), on-device by default
- **Text-to-speech**: `SystemTTSClient` renders the whole reply with `AVSpeechSynthesizer.write` and plays it through `AVAudioEngine` (one utterance, short silent lead-in, default rate 0.44)
- **Screen capture**: ScreenCaptureKit, multi-monitor; YoClicky's own windows are excluded. Screenshots are sized to the model's image tier (1920 px for Sonnet/Opus, 1280 for Haiku) and kept under its visual-token limit, since a server-side downscale would shift pointing coordinates. A 2x close-up around the cursor is added for reading small text (never used for coordinates)
- **Context**: `ScreenContextReader` adds the frontmost app, window title, selected text (Accessibility) and the date/time to each question
- **Pointing**: Claude appends `[POINT:x,y:label:screenN]`; `CompanionManager.parsePointingCoordinates` maps it to screen coordinates
- **Memory**: Claude marks lasting facts with `[REMEMBER: ...]`; `MemoryStore` saves them to `~/Library/Application Support/YoClicky/memories.json`
- **Open document**: `OpenDocumentReader` reads the file shown in the frontmost app's window (Accessibility `AXDocument`) when the question is about it
- **Dictation**: a second hold shortcut (default `control + shift`) types the transcript into the focused field (`DictationTextInserter`, paste + clipboard restore)
- **Look**: Liquid Glass (`GlassStyle.swift`, `NSGlassEffectView` on macOS 26, blur fallback on 14-15); semantic colors in `DesignSystem.swift`
- **Logs**: `print` output goes to `~/Library/Logs/YoClicky/yoclicky.log` when not launched from a terminal (`AppLogFile`)

## Key Files

| File | Purpose |
|------|---------|
| `leanring_buddyApp.swift` | App entry, app delegate, legacy settings migration |
| `CompanionManager.swift` | Central state: shortcuts, dictation, screenshot → Claude → TTS pipeline, pointing, text chat, prompts |
| `ClaudeCodeCLI.swift` | Claude Code CLI client, warm process pool, errors, diagnostics |
| `AIProvider.swift` | Provider list, `AIProviderClient` protocol, per-provider model settings |
| `ResponseRouter.swift` | Per-question model, effort and screenshot size (the "Auto" model) |
| `ScreenContextReader.swift` | App name, window title, selected text and date sent with each question |
| `ClickySettings.swift` | All user preferences (shortcuts, language, voice, screenshots, memory…) and sounds |
| `SettingsWindow.swift` | Settings window (General, AI, Voice, Appearance, Shortcuts, Privacy) and shortcut recorder |
| `CompanionPanelView.swift` | Menu bar panel: permissions, onboarding copy, AI/model/style pickers |
| `TextChatWindow.swift` | Floating text chat (double-tap a modifier key) |
| `OverlayWindow.swift` | Cursor overlay, pointing flight animation, welcome/onboarding bubbles |
| `GlobalPushToTalkShortcutMonitor.swift` | CGEvent tap: push-to-talk, dictation, double-tap detection |
| `BuddyDictationManager.swift` | Mic capture and transcription sessions; push-to-talk shortcut matching |
| `SystemTTSClient.swift` | macOS voice rendering and playback |
| `MemoryStore.swift` | Long-term memory storage and `[REMEMBER]` parsing |
| `OpenDocumentReader.swift` | Reads the open document; tracks the last non-YoClicky app |
| `DictationTextInserter.swift` | Types dictated text into the focused field |
| `GlassStyle.swift` / `DesignSystem.swift` | Liquid Glass components and design tokens |
| `AppLogFile.swift` | Log file redirection and "Open Logs" |

## Build & Run

```sh
scripts/build-local.sh   # build, sign with a stable identity, install to /Applications
scripts/build-dmg.sh     # build dist/YoClicky-<version>.dmg (universal, ad-hoc or Developer ID signed)
```

Requires Xcode 26+ (macOS 26 SDK for Liquid Glass); the app runs on macOS 14.2+.

- Always build with `scripts/build-local.sh`, not Xcode's Run button: it signs with the same certificate every time, so macOS keeps the app's permissions (microphone, screen recording, accessibility) between builds. Ad-hoc signed builds look like a new app to macOS and lose them.
- Claude Code must be installed and logged in (`claude` in a terminal) for AI requests to work. Settings > AI > Test Connection checks it.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- All buttons must show a pointer cursor on hover
- Settings descriptions should describe the current choice, not stay static
- Use the glass components in `GlassStyle.swift` and semantic colors from `DesignSystem.swift`

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated APIs in untouched code)
- Do not rename the project directory or scheme (the "leanring" typo is legacy from the original Clicky)
- Do not add analytics, remote logging or any server the user didn't ask for
