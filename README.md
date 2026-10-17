<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <img src="docs/logo.svg" width="96" alt="Critique logo">
  </picture>
</p>

<h1 align="center">Critique</h1>

<p align="center">
  <b>Show your coding agent what's wrong, the way you'd show a teammate.</b><br>
  Talk, point at your screen, and Critique hands it all to your agent.<br>
  <a href="https://mmerioles.github.io/critique/">Website</a> · <a href="https://github.com/mmerioles/critique/releases/latest">Download</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.1.0-ff3b30" alt="Version 0.1.0">
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-000000?logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/works%20with-Claude%20Code-D97757" alt="Works with Claude Code">
</p>

```
 double-tap right ⌥  →  talk + point  →  double-tap right ⌥  →  your agent has it
```

## Install

Requires macOS 15+ and Xcode (or the Swift command line tools).

```sh
make install     # builds, copies to /Applications, launches
# or
make run         # builds and launches from ./build
```

On first launch, allow Critique in **System Settings → Privacy & Security**:

| Permission | Why |
|---|---|
| Screen Recording | See your screen |
| Input Monitoring | Notice the right ⌥ double-tap |
| Accessibility | Box the exact button you point at |
| Microphone + Speech Recognition | On-device dictation |

Permissions on but not working? Run `tccutil reset All dev.critique.app` and allow again.

## How it works

1. **Double-tap right Option** anywhere. A red ring follows your cursor.
2. **Talk, and mark up what you mean:**
   - **Hold `` ` ``** and move the mouse to draw. Each drawing takes a whole-screen screenshot.
   - Clicks and hovers are logged too, without screenshots.
3. **Double-tap right Option again to send.** `esc` cancels.

Every critique shows up in the Critique app with its time, your words, and your marked-up screenshots.

Your agent gets your words, a screen recording, marked-up screenshots, and a timeline that lines them up:

> The header looks fine but **[#1]** this button is way too big and this text is cut off.
>
> - 0:00.9 clicked menu button “File”
> - 0:01.6 hovered menu item “Export…” · frame: `…/frames/0-01.8.jpg`
> - 0:04.2 #1 drew around button “Sign up”, link “Cancel”

## Getting feedback to your agent

When you send, Critique types one line into Claude Code and presses Enter for you: `Implement my UX feedback from Critique: …/feedback.md`.

The feedback is also on your clipboard, saved in `~/.critique/inbox/`, and available over MCP:

```sh
claude mcp add critique -- /Applications/Critique.app/Contents/MacOS/Critique mcp
```
