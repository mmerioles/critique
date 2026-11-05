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
  <img src="https://img.shields.io/badge/version-0.2.0-ff3b30" alt="Version 0.2.0">
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-000000?logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/works%20with-Claude%20Code-D97757" alt="Works with Claude Code">
</p>

```
 double-tap `  →  talk + point  →  double-tap `  →  your agent has it
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
| Input Monitoring | Notice the ` double-tap |
| Accessibility | Box the exact button you point at |
| Microphone + Speech Recognition | On-device dictation |

Permissions on but not working? Run `tccutil reset All dev.critique.app` and allow again.

### Updates

Critique checks GitHub for a newer release shortly after launch and once a day. When there is one, the status menu gets an **Update to 0.x.y…** item and the sidebar shows a banner; both download the new DMG, which you drag over the old app. **Check for Updates…** in the menu checks on demand. To turn off the automatic check:

```sh
defaults write dev.critique.app updates.check -bool false
```

## How it works

1. **Double-tap `** (the key above Tab) anywhere. A red ring follows your cursor.
2. **Talk, and mark up what you mean:**
   - **Hold `` ` ``** and move the mouse to draw. Each drawing takes a whole-screen screenshot.
   - Clicks and hovers are logged too, without screenshots.
3. **Double-tap ` again to send.** `esc` cancels.

Every critique shows up in the Critique app with its time, your words, and your marked-up screenshots.

Your agent gets your words, a screen recording, marked-up screenshots, and a timeline that lines them up:

> The header looks fine but **[#1]** this button is way too big and this text is cut off.
>
> - 0:00.9 clicked menu button “File”
> - 0:01.6 hovered menu item “Export…” · frame: `…/frames/0-01.8.jpg`
> - 0:04.2 #1 drew around button “Sign up”, link “Cancel”

## Critique from your Android phone

The **Mobile** page lets you critique an Android app while you hold the phone.

1. Phone and Mac on the same Wi‑Fi. On the phone: Developer options → **Wireless debugging** → Pair device with pairing code. Enter it on the Mobile page.
2. Click **Install tile**. Critique installs a small helper and adds a **Critique** tile to Quick Settings.
3. Tap the tile, use the app and talk, tap it again to send. Critique records the phone's screen and mic over adb ([scrcpy](https://github.com/Genymobile/scrcpy), `brew install scrcpy`), and each tap becomes a screenshot with a ring where your finger was.
4. When the agent is done, Critique runs `./gradlew installDebug` for the project and reopens the app on your phone.

**See your phone on your Mac.** Once a phone is paired, switch on **Show phone screen** on the Mobile page to stream it live (about a tenth of a second behind). Click **Full screen**, or double-click the picture, to watch it full screen; switch it off when you're done. It uses scrcpy's phone-side server over adb and decodes the H.264 stream on your Mac, so it runs alongside a critique recording.

The helper's source is in `android-helper/` (`make helper` rebuilds it).

## Getting feedback to your agent

When you send, Critique types one line into Claude Code and presses Enter for you: `Implement my UX feedback from Critique: …/feedback.md`.

The feedback is also on your clipboard, saved in `~/.critique/inbox/`, and available over MCP:

```sh
claude mcp add critique -- /Applications/Critique.app/Contents/MacOS/Critique mcp
```

### Pick a project

The Repos tab lists the git projects on your Mac and your GitHub repos. Pick one and every critique is tagged with it. Over MCP, an agent only picks up critiques for the folder it's running in. Critiques with no project go to any agent.

Click **Check for Updates** (or the refresh button on a repo) to fetch from GitHub and see what's new upstream. Nothing is pulled until you click **Pull** on a repo or **Update All**. Both only fast-forward, so a repo with local commits or conflicting changes is left as it is. Click a repo's branch to switch to another one, including branches that are only on origin.

### Run an agent from Critique

The Agent tab runs one main agent (Claude Code, Codex or Gemini CLI, with the model you pick) in your projects folder: `~/repos` unless you choose another. It runs in the background with no window. **Show** opens its terminal, and closing that window keeps it running. Every critique goes to it along with the project it's for, so it can work in any of your repos. It stops when you quit Critique.

Claude Code runs **headless** by default: no terminal, one `claude -p` session per project in that project's folder, which Critique talks to over JSON and picks up again (`--resume`) after a restart. Each session starts with the first critique for its project and gets the whole feedback as its message. **Show** opens a transcript of what it was told, said and did. Switch Headless off on the Agent tab for a real terminal session at the top of your projects folder; there, Critique learns the session's status from Claude Code hooks (passed with `--settings`, alongside your own) rather than by reading its screen.

The top of the tab shows your Claude plan usage, the 5-hour window and the week, the same numbers as `/usage`. It reads Claude Code's saved sign-in from your keychain.

## Releasing

Push a tag to publish a build: `git tag v0.2.0 && git push --tags`. The Release workflow builds the DMG and attaches it to a GitHub release. Bump `CFBundleShortVersionString` in `Resources/Info.plist` (and the badge above) first; the in-app update check compares it with the tag.

Without signing secrets the DMG is ad-hoc signed: it runs, but macOS warns on first open and resets the app's permissions on every build. Add these repository secrets and the workflow signs with your Developer ID, notarizes the DMG with Apple and staples the ticket, so it opens cleanly:

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE_P12` | Your **Developer ID Application** certificate and private key as a base64 `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you gave the `.p12` when exporting it |
| `APPLE_ID` | The Apple ID of your developer account |
| `APPLE_TEAM_ID` | Your 10-character team ID (Apple Developer → Membership) |
| `APPLE_APP_PASSWORD` | An app-specific password for that Apple ID |

One-time setup:

1. In Xcode → Settings → Accounts → your team → **Manage Certificates…** → **+** → **Developer ID Application** (needs a paid Apple Developer account; only the account holder can make this kind of certificate).
2. In Keychain Access, find the "Developer ID Application: …" certificate, expand it so the private key shows, select both, and **File → Export Items…** as a `.p12` with a password. Then `base64 -i cert.p12 | pbcopy` and paste it into `MACOS_CERTIFICATE_P12`.
3. At [account.apple.com](https://account.apple.com) → Sign-In and Security → **App-Specific Passwords**, make one for notarization and put it in `APPLE_APP_PASSWORD`.

Locally, `make app` signs with whatever Apple Development certificate you have (or ad-hoc if none), using the same hardened runtime and `Resources/Critique.entitlements`. To sign a local build with the Developer ID instead: `make dmg SIGN_ID="Developer ID Application: Your Name (TEAMID)"`.

Next step: [Sparkle](https://sparkle-project.org) would update the app in place instead of handing you a DMG. It needs an appcast feed published with each release and an EdDSA key pair (`generate_keys`) whose public key goes in Info.plist and whose private key signs every DMG; set those up and the updater in `Sources/Critique/Updater.swift` can hand over to it.
