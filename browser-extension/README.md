# Critique browser extension

Draw around a button in a web app and your agent gets more than `button “Sign up”`: the
CSS selector, `data-testid`, the React/Vue/Svelte component it belongs to (with the source
file and line in dev builds), its text, and the page URL. Each DOM line lands in
`feedback.md` under the screenshot it belongs to.

Works in Chrome, Chromium, Arc, Brave and Edge (Manifest V3). Firefox 128+ loads it too.
Safari isn't supported.

## Load unpacked

1. Open `chrome://extensions` (Arc: `arc://extensions`, Brave: `brave://extensions`,
   Edge: `edge://extensions`).
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and pick this folder (`browser-extension/`).
4. Open Critique. The extension's badge shows **on** once it's connected, and Critique's
   Connect page says "Browser extension: connected".

Firefox: `about:debugging` → **This Firefox** → **Load Temporary Add-on…** → pick
`manifest.json`. Then, in the add-on's **Permissions** tab, allow access to all sites
(Firefox treats `host_permissions` as optional).

Pages that were already open before you loaded the extension work too: the extension injects
its inspector on demand, so there's nothing to reload.

## How it works

- `background.js` (service worker) keeps a WebSocket to Critique at `ws://127.0.0.1:48213`,
  reconnecting with backoff while Critique isn't running. A 20 s ping keeps the worker alive
  while connected; an alarm wakes it every 30 s otherwise so it notices when Critique starts.
- When you draw on a browser window, Critique sends
  `{type: "elements", id, screen: {x, y, w, h}, scale, hint}` — the drawn area in global
  screen points, the display's backing scale, and what macOS Accessibility saw there.
- The worker finds the browser window under that rect (`chrome.windows` bounds are in the
  same screen points on macOS) and runs `inspect.js` in its active tab with
  `chrome.scripting.executeScript({world: "MAIN"})`. It has to be the page's own world:
  React's `__reactFiber$…`, Vue's `__vueParentComponent` and Svelte's `__svelte_meta` are
  expando properties that an isolated content script can't see.
- `inspect.js` maps screen points to viewport points, samples `document.elementsFromPoint`
  over a small grid in the rect, and replies with the distinct elements it found: tag, id,
  classes, a short unique selector, test id, role, aria-label, text (≤ 80 chars), bounding
  rect, and framework hints. Input values are never sent, only placeholders.
- `popup.html` shows the connection state.

Critique only accepts connections from `chrome-extension://` and `moz-extension://` origins,
on the loopback interface.

## Screen → viewport mapping, and its limits

The viewport's position on screen isn't exposed to pages, so it's worked out:

- `window.screenX/screenY` and `outerWidth/outerHeight` are in screen points on macOS, while
  `innerWidth/innerHeight` are in CSS px. Page zoom is `devicePixelRatio / backing scale`.
- The browser chrome (tab strip, toolbar, bookmarks bar) is assumed to sit on top:
  `chromeTop = outerHeight − innerHeight·zoom`. DevTools docked at the bottom, or a download
  shelf, get counted as top chrome and shift the sampled points up.
- Anything shrinking the viewport sideways (Arc's sidebar, Chrome's side panel, DevTools
  docked left or right) is tried on the left first, then on the right; the Accessibility hint
  (`button “Sign up”`) picks whichever finds matching text.
- Only the top document is inspected (no iframes), and pinch zoom isn't accounted for.
- Multiple monitors work as long as the browser reports window positions in the global
  coordinate space, which Chromium browsers do on macOS.

## React source locations

`_debugSource` (file:line of the JSX) exists in React ≤ 18 development builds. React 19
dropped it; the extension then reads the JSX call site from `_debugStack` when present.
Production builds have component names only when they survive minification.
