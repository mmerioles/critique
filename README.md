# Critique

**Talk to your coding agent about your app the way you'd talk to a teammate looking at your screen.**

Double-tap right Option, then talk and point with your cursor. Critique records your voice, your screen, and what you point at, and hands it all to your coding agent.

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

On first use, macOS asks for a few permissions. Each one is used for:
- **Screen Recording**, so Critique can see your screen. You may need to reopen the app after allowing it.
- **Input Monitoring**, so Critique can notice the right Option double-tap. Until you allow it, `⌃⌥Space` works as a backup.
- **Accessibility**, so Critique can find the exact button or text you point at and box it.
- **Microphone + Speech Recognition**, for dictation. This runs on-device.

> `make` signs with your Apple Development certificate if you have one, so permissions stick across rebuilds. If permissions look on but don't work, run `tccutil reset All dev.critique.app`, reopen the app, and allow again.

## How it works

1. **Double-tap right Option** anywhere. A small pill shows your voice as a waveform, and a red ring follows your cursor.
2. **Talk and point:**
   - **Rest** on something, and it gets a red box.
   - **Hold `` ` ``** and move the mouse to draw.
   - **Click or hover**, and it's logged.
3. **Double-tap right Option again to send.** `esc` cancels.

Your agent gets your words, a screen recording, marked-up screenshots, and a timeline that lines them up:

> The header looks fine but **[#2]** this button is way too big **[#3]** and this text is cut off.
>
> - 0:00.9 clicked menu button “File”
> - 0:01.6 hovered menu item “Export…” · frame: `…/frames/0-01.8.jpg`
> - 0:02.4 #2 pointing at button “Sign up”
> - 0:04.2 #3 drew around button “Sign up”, link “Cancel”

## Getting feedback to your agent

When you send, Critique switches back to Claude Code and types one line into the prompt:

```
> Implement my UX feedback from Critique: ~/.critique/inbox/…/feedback.md (4 screenshots, 0:38 recording). …
```

Press **Enter** to implement. It only types into a terminal tab where Claude Code is running. Otherwise, the full feedback is on your clipboard to paste. You can turn this off from the menu bar: *Paste Into Agent After Sending*.

Other ways your agent can get it:

- **MCP:** `claude mcp add critique -- /Applications/Critique.app/Contents/MacOS/Critique mcp`. Then tell your agent *"wait for my UX feedback and fix it"*.
- **Files:** everything is saved to `~/.critique/inbox/<time>/`. `Critique latest` prints the newest one.
