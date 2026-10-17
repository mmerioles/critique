# UX Flow

**Talk to your coding agent about your app the way you'd talk to a teammate looking at your screen.**

Double-tap right Option, then talk and point with your cursor, the way you would if a teammate were looking at your screen. To mark something up, hold the backtick key (`) and move the mouse to draw. UX Flow watches your cursor, listens to your voice, records your screen, and sends all of it to your coding agent.

```
 double-tap right ⌥  →  talk + point  →  double-tap right ⌥  →  your agent has it
```

## How it works

1. **Double-tap the right Option key** anywhere. A small pill shows your voice as a live waveform, and a red ring appears around your cursor.
2. **Talk and point.** Your cursor is your finger:
   - **Rest on something** while talking, and a red box snaps around that button, text or image.
   - **Hold `` ` `` and move the mouse** to draw on your screen in red, no clicking needed. Let go, and the drawing is captured along with every button, link and field inside it.
   - **Click something**, and UX Flow captures what the click did.
   - **Hover over things.** Each button, link or menu item you hover or click is logged, even things too fleeting to screenshot, like a menu that flickers.
3. **Double-tap right Option again to send.** (`esc` cancels. While a session is running, `` ` `` draws instead of typing.)

Everything is captured on one shared clock:

| What | How |
|---|---|
| **Your voice** | Transcribed on-device with the Mac's built-in speech recognition |
| **Screen recording** | Video of your screen with your voice, including the red ring and boxes |
| **Screenshots** | One per point, drawing or click, with your red box or stroke drawn in, plus a zoomed-in crop |
| **What you pointed at** | e.g. `button “Sign up”`, read from macOS Accessibility |
| **Hovers and clicks** | Every interactive element you touch, with its time on the recording |
| **Video frames** | Stills pulled from the recording for moments with no screenshot |

Your agent gets something like this:

> The header looks fine but **[#2]** this button is way too big **[#3]** and this text is cut off.
>
> **Timeline**
> - 0:00.0 said “So when I open this menu the export option”
> - 0:00.9 clicked menu button “File”
> - 0:01.6 hovered menu item “Export…” · frame: `…/frames/0-01.8.jpg`
> - 0:02.4 #2 pointing at button “Sign up”
> - 0:04.2 #3 drew around button “Sign up”, link “Cancel”

## Getting feedback to your agent

**When you send, your feedback lands in your agent's prompt.** UX Flow brings your terminal (or editor) back to the front and pastes the feedback into the Claude Code prompt:

```
> [Pasted text #1 +42 lines] Implement the UX feedback above (UX Flow: 4 screenshots, 0:38 recording).
```

Press **Enter** to implement. Nothing is submitted until you do. UX Flow pastes into whichever terminal or editor you used last (iTerm, Terminal, Ghostty, Warp, VS Code, Cursor and others). You can turn this off from the menu bar: *Paste Into Agent After Sending*.

UX Flow also hands the feedback over in these ways:

- **Clipboard:** the feedback is copied, so you can paste it into any agent yourself.
- **MCP:** agents can pull it directly. For Claude Code:
  ```sh
  claude mcp add uxflow -- /Applications/UXFlow.app/Contents/MacOS/UXFlow mcp
  ```
  The menu bar item → *Connect Claude Code* copies this command for you. Then tell your agent *"wait for my UX feedback and fix it"*. It calls `wait_for_feedback`, you double-tap right Option and talk, and it starts working as soon as you send.
- **Files:** everything is saved to `~/.uxflow/inbox/<time>/` (`feedback.md` plus the screenshots). `UXFlow latest` prints the newest one.

MCP tools: `get_feedback` (unread or latest), `wait_for_feedback` (blocks until you send), `list_feedback`.

## Install

Requires macOS 14+ and Xcode (or the Swift command line tools).

```sh
make install     # builds, copies to /Applications, launches
# or
make run         # builds and launches from ./build
```

On first use, macOS asks for a few permissions. Each one is used for:
- **Screen Recording**, so UX Flow can see your screen. You may need to reopen the app after allowing it.
- **Input Monitoring**, so UX Flow can notice the right Option double-tap. Until you allow it, `⌃⌥Space` works as a backup.
- **Accessibility**, so UX Flow can find the exact button or text you point at and box it. Without it, you get a ring at the cursor instead of a box.
- **Microphone + Speech Recognition**, for dictation. This runs on-device when your Mac supports it. Without it, UX Flow falls back to typing.

> `make` signs with your Apple Development certificate if you have one, so permissions stick across rebuilds. Without one, the build is ad-hoc signed and macOS asks again after every rebuild. If permissions look on but don't work, run `tccutil reset All dev.uxflow.app`, reopen the app, and allow again.

## Code map

```
Sources/UXFlow/
  main.swift            app / `mcp` / `latest` entry point
  AppDelegate.swift     menu bar item
  FlowController.swift  the session: start, highlight, snap, type, send
  FlowBar.swift         the floating bar UI
  Dictation.swift       live speech-to-text
  ScreenCapture.swift   screenshots + which app/window you're pointing at
  FeedbackWriter.swift  annotates screenshots, writes to the inbox
  Inbox.swift           on-disk format + Markdown for agents
  MCPServer.swift       MCP server for coding agents
  RightOptionTap.swift  double-tap right Option detection
  AgentHandoff.swift    pastes feedback into your agent's prompt after sending
  PointerTracker.swift  cursor ring, red boxes, drawing with `, rest / click / hover
  ElementLocator.swift  finds the button/text under the cursor (Accessibility)
  ScreenRecorder.swift  screen + voice video of the session
  HotKeys.swift         ` to draw, esc to cancel, ⌃⌥Space backup trigger
```
