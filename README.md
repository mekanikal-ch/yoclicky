<p align="center">
  <img src="design/AppIcon-1024.png" width="128" alt="YoClicky icon">
</p>

<h1 align="center">YoClicky</h1>

<p align="center">
  An AI buddy that lives next to your cursor on macOS. It sees your screen, talks with you, and points at things.<br>
  Runs on <b>your own Claude subscription</b>, so there's no extra subscription to pay.
</p>

<p align="center">
  <a href="https://github.com/mekanikal-ch/yoclicky/releases/latest"><b>Download for macOS</b></a>
  ·
  <a href="#install">Install</a>
  ·
  <a href="#how-it-works">How it works</a>
  ·
  <a href="#build-from-source">Build from source</a>
</p>

https://github.com/user-attachments/assets/74c5427b-ddbb-4436-b680-4bc5aa3d568c





---

## What it is

YoClicky is a free, open-source take on [Clicky / HeyClicky](https://www.heyclicky.com/). Hold a shortcut, ask a question out loud, and a small cursor next to yours answers, then flies over to the button, menu or line of code it's talking about.

HeyClicky routes everything through its own servers and charges a subscription. YoClicky instead uses the **Claude Code** command-line tool already on your Mac, logged in with **your Claude Pro or Max plan**. No API keys, no accounts, no YoClicky servers.

## Features

- **Ask about your screen.** Hold `control + option`, speak, release. YoClicky looks at your screen, answers out loud, and points at what it means.
- **Picks the right model.** Auto mode sends everyday questions to Sonnet and math, code and "why" questions to Opus. It reads small text through a sharp close-up of the area around your cursor, and uses the exact text you've selected.
- **Text chat.** Double-tap `control` for a chat window, when you can't talk.
- **Dictation anywhere.** Hold `control + shift` and speak: your words are typed into whatever text field you're in. Uses no tokens.
- **Reads the whole document.** Ask "summarize this PDF" and it reads the entire file open in Preview, TextEdit, Xcode, Word…, not just what's visible.
- **Memory.** Tell it something once ("I study at ETH") and it remembers it between sessions. You can view and delete every memory.
- **Saves tokens.** Caveman style (very short answers), Auto / Haiku / Sonnet / Opus, choose what screenshots to send and how much history.
- **Your language.** Listens, speaks and answers in English, French, German, Spanish and more, with any macOS voice.
- **Liquid Glass design,** custom cursor color, hide-until-needed cursor, custom shortcuts.

## Requirements

- macOS 14.2 or later, Apple Silicon or Intel
- A Claude **Pro or Max** subscription
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and logged in:
  ```sh
  curl -fsSL https://claude.ai/install.sh | bash
  claude   # log in once with your Claude account, then quit
  ```

## Install

1. Download `YoClicky-x.y.dmg` from the [latest release](https://github.com/mekanikal-ch/yoclicky/releases/latest).
2. Open it and drag **YoClicky** into **Applications**.
3. Open YoClicky from Applications. The first time, macOS blocks it (see [First launch](#first-launch-open-anyway) below).
4. Click the YoClicky icon in the menu bar and grant the four permissions it asks for:
   - **Microphone** and **Speech Recognition**, to hear you
   - **Screen Recording**, to see your screen when you ask something
   - **Accessibility**, for the global shortcuts, pointing and dictation
5. Click **Start**. That's it.

In **Settings → AI → Test Connection** you can check that YoClicky reaches Claude with your account.

### First launch: "Open Anyway"

<!-- Remove this section once releases are notarized. -->
YoClicky is free and not notarized by Apple (that costs $99 a year), so the first time you open it macOS says it "could not verify" the app. That's expected. You only do this once:

1. Click **Done** in the warning (not "Move to Trash").
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Next to *"YoClicky" was blocked*, click **Open Anyway**, then confirm with your password or Touch ID.

Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/YoClicky.app`, then open it normally.

The code is all here, and you can [build it yourself](#build-from-source) if you'd rather not trust a download.

## Shortcuts

| Shortcut | What it does |
|---|---|
| Hold `control + option` | Ask YoClicky out loud |
| Double-tap `control` | Open or close the text chat |
| Hold `control + shift` | Dictate into the current text field |

All of them can be changed in **Settings → Shortcuts**.

## How it works

```
you speak ──► Apple speech recognition (on your Mac)
                  │
                  ▼
      question + screenshot ──► `claude -p` (Claude Code CLI, your account) ──► answer
                                                                      │
                  ┌───────────────────────────────────────────────────┘
                  ▼
      macOS voice reads it out, the cursor flies to what it's pointing at
```

- Nothing runs in the background. A screenshot is taken only when you release the talk shortcut or send a chat message, and it's never saved.
- Your voice is transcribed by Apple, on-device by default.
- Your question and screenshot go to Claude through the official Claude Code CLI, using your own login. Usage counts toward your plan's normal limits.
- Settings, memories and the conversation stay on your Mac. No analytics, no tracking.

## FAQ

**Is it really free?**
YoClicky is free. It needs a Claude Pro or Max plan, which you may already have. It uses that plan instead of a second subscription.

**How much of my Claude plan does it use?**
A question is roughly 5,000 tokens with a screenshot and the cursor close-up, or about 1,500 in Caveman style. Questions Auto sends to Opus use your plan faster than Sonnet. Settings → AI explains what each option costs.

**Is it affiliated with Anthropic or HeyClicky?**
No. It's an independent open-source project built on the MIT-licensed original Clicky. It uses Anthropic's official Claude Code CLI; please follow [Anthropic's usage policies and terms](https://www.anthropic.com/legal) for your plan.

**Why is my Mac warning me when I open it?**
Releases aren't notarized by Apple yet, which requires a paid Apple developer account. See step 3 of [Install](#install), or [build it yourself](#build-from-source).

**Something doesn't work.**
Settings → General → Open Logs shows what happened. Please [open an issue](https://github.com/mekanikal-ch/yoclicky/issues) and include the relevant lines.

## Build from source

Needs Xcode 26 or later (the Liquid Glass code needs the macOS 26 SDK; the app itself still runs on macOS 14.2+).

```sh
git clone https://github.com/mekanikal-ch/yoclicky.git
cd yoclicky
open leanring-buddy.xcodeproj    # or build from the command line:

SIGN_IDENTITY="Apple Development" scripts/build-local.sh   # builds, signs and installs to /Applications
scripts/build-dmg.sh                                        # builds dist/YoClicky-<version>.dmg
```

`build-local.sh` signs with a certificate from your keychain, so macOS keeps your permissions between rebuilds. List yours with `security find-identity -v -p codesigning`.

## Credits

- Based on [Clicky](https://github.com/farzaa/clicky) by [Farza](https://x.com/FarzaTV), released under the MIT license. Thank you for open-sourcing it.
- YoClicky changes: Claude Code backend, macOS voices and speech, text chat, dictation, document reading, memory, settings, Liquid Glass UI.

## License

MIT, see [LICENSE](LICENSE).
