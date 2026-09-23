<p align="center">
  <img src="design/AppIcon-1024.png" width="128" alt="YoClicky icon">
</p>

<h1 align="center">YoClicky</h1>

<p align="center">
  An AI buddy that lives next to your cursor on macOS. It sees your screen, talks with you, and points at things.<br>
  Runs on <b>your own Claude subscription</b>, so there's no extra subscription to pay.
</p>

<p align="center">
  <a href="https://github.com/YOUR_GITHUB_USERNAME/yoclicky/releases/latest"><b>Download for macOS</b></a>
  ·
  <a href="#install">Install</a>
  ·
  <a href="#how-it-works">How it works</a>
  ·
  <a href="#build-from-source">Build from source</a>
</p>

<!-- Replace with a short screen recording of YoClicky pointing at something (docs/demo.gif). -->
<p align="center"><img src="docs/demo.gif" width="720" alt="YoClicky pointing at a button while answering a question"></p>

---

## What it is

YoClicky is a free, open-source take on [Clicky / HeyClicky](https://www.heyclicky.com/). Hold a shortcut, ask a question out loud, and a small cursor next to yours answers, then flies over to the button, menu or line of code it's talking about.

HeyClicky routes everything through its own servers and charges a subscription. YoClicky instead uses the **Claude Code** command-line tool already on your Mac, logged in with **your Claude Pro or Max plan**. No API keys, no accounts, no YoClicky servers.

## Features

- **Ask about your screen.** Hold `control + option`, speak, release. YoClicky looks at your screen, answers out loud, and points at what it means.
- **Text chat.** Double-tap `control` for a chat window, when you can't talk.
- **Dictation anywhere.** Hold `control + shift` and speak: your words are typed into whatever text field you're in. Uses no tokens.
- **Reads the whole document.** Ask "summarize this PDF" and it reads the entire file open in Preview, TextEdit, Xcode, Word…, not just what's visible.
- **Memory.** Tell it something once ("I study at ETH") and it remembers it between sessions. You can view and delete every memory.
- **Saves tokens.** Caveman style (very short answers), Haiku / Sonnet / Opus, choose what screenshots to send and how much history.
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

1. Download `YoClicky-x.y.dmg` from the [latest release](https://github.com/YOUR_GITHUB_USERNAME/yoclicky/releases/latest).
2. Open it and drag **YoClicky** into **Applications**.
3. Open YoClicky from Applications.
   <!-- Remove this step once releases are notarized. -->
   YoClicky isn't notarized by Apple yet, so macOS will say it can't verify the developer. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only do this once.
4. Click the YoClicky icon in the menu bar and grant the four permissions it asks for:
   - **Microphone** and **Speech Recognition**, to hear you
   - **Screen Recording**, to see your screen when you ask something
   - **Accessibility**, for the global shortcuts, pointing and dictation
5. Click **Start**. That's it.

In **Settings → AI → Test Connection** you can check that YoClicky reaches Claude with your account.

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
A question is roughly 2,500 tokens with a screenshot, or about half that in Caveman style with Haiku. Settings → AI explains what each option costs.

**Is it affiliated with Anthropic or HeyClicky?**
No. It's an independent open-source project built on the MIT-licensed original Clicky. It uses Anthropic's official Claude Code CLI; please follow [Anthropic's usage policies and terms](https://www.anthropic.com/legal) for your plan.

**Why is my Mac warning me when I open it?**
Releases aren't notarized by Apple yet, which requires a paid Apple developer account. See step 3 of [Install](#install), or [build it yourself](#build-from-source).

**Something doesn't work.**
Settings → General → Open Logs shows what happened. Please [open an issue](https://github.com/YOUR_GITHUB_USERNAME/yoclicky/issues) and include the relevant lines.

## Build from source

Needs Xcode 26 or later (the Liquid Glass code needs the macOS 26 SDK; the app itself still runs on macOS 14.2+).

```sh
git clone https://github.com/YOUR_GITHUB_USERNAME/yoclicky.git
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
