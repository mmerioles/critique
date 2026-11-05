// Keeps a WebSocket open to Critique (ws://127.0.0.1:48213) and answers its
// "which DOM elements are here?" questions by running inspect.js in the page
// under the drawing.
//
// Protocol (JSON text frames):
//   → {type: "hello", browser, version}            on connect
//   → {type: "ping"} / ← {type: "pong"}             every 20 s, which also keeps this worker alive
//   ← {type: "elements", id, screen: {x, y, w, h}, scale, hint}
//   → {type: "elements", id, url, title, matched, elements: [...]}   or   {type: "elements", id, error}
//
// Reconnects with backoff while Critique isn't running. Chrome stops an idle
// service worker after 30 s, so an alarm wakes it up to try again.

if (typeof inspectPage === "undefined" && typeof importScripts === "function") importScripts("inspect.js");

const api = globalThis.browser ?? globalThis.chrome;
const CRITIQUE = "ws://127.0.0.1:48213";
const PING_EVERY = 20_000;
const MIN_BACKOFF = 1_000, MAX_BACKOFF = 30_000;

let socket = null;
let state = "disconnected"; // disconnected | connecting | connected
let backoff = MIN_BACKOFF;
let retryTimer = null, pingTimer = null;
let lastError = null;
let lastRequestAt = null;
let answered = 0;

function browserName() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands || []).map(b => b.brand);
  for (const known of ["Brave", "Microsoft Edge", "Opera", "Vivaldi", "Arc", "Google Chrome", "Chromium"]) {
    if (brands.includes(known)) return known;
  }
  if (/Firefox/.test(navigator.userAgent)) return "Firefox";
  return brands.find(b => !/Not.?A.?Brand/i.test(b)) || "Browser";
}

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  clearTimeout(retryTimer);
  state = "connecting";
  let ws;
  try {
    ws = new WebSocket(CRITIQUE);
  } catch (e) {
    lastError = String(e);
    state = "disconnected";
    scheduleRetry();
    return;
  }
  socket = ws;
  ws.onopen = () => {
    state = "connected";
    backoff = MIN_BACKOFF;
    lastError = null;
    send({ type: "hello", browser: browserName(), version: api.runtime.getManifest().version });
    clearInterval(pingTimer);
    pingTimer = setInterval(() => send({ type: "ping" }), PING_EVERY);
    showState();
  };
  ws.onmessage = event => {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    handle(message);
  };
  ws.onerror = () => { lastError = "Critique isn't listening on " + CRITIQUE; };
  ws.onclose = () => {
    if (socket === ws) socket = null;
    state = "disconnected";
    clearInterval(pingTimer);
    showState();
    scheduleRetry();
  };
}

function scheduleRetry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, backoff);
  backoff = Math.min(MAX_BACKOFF, backoff * 2);
}

function send(message) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

async function handle(message) {
  switch (message.type) {
    case "pong":
      break;
    case "ping":
      send({ type: "pong" });
      break;
    case "elements": {
      lastRequestAt = Date.now();
      let reply;
      try {
        reply = await elements(message);
      } catch (e) {
        reply = { error: String(e && e.message || e) };
      }
      answered++;
      send({ type: "elements", id: message.id, ...reply });
      break;
    }
  }
}

// Finds the window under the drawing, then asks its active tab's page.
async function elements(req) {
  const screen = req.screen || {};
  const cx = screen.x + screen.w / 2, cy = screen.y + screen.h / 2;
  const windows = await api.windows.getAll({ populate: true, windowTypes: ["normal", "popup", "app"] });
  const open = windows.filter(w => w.state !== "minimized" && w.tabs && w.tabs.length);
  // Window bounds are in screen points, the same space as Critique's rect (on macOS).
  const under = open.filter(w => cx >= w.left && cx < w.left + w.width && cy >= w.top && cy < w.top + w.height);
  let matched = true;
  let win = under.find(w => w.focused) || under[0];
  if (!win) {
    // Nothing of ours there (another browser, probably). Answer anyway, marked as a guess.
    matched = false;
    win = open.find(w => w.focused) || open[0];
  }
  if (!win) return { error: "no browser window" };
  const tab = win.tabs.find(t => t.active) || win.tabs[0];
  if (!tab || tab.id == null) return { error: "no active tab" };
  const url = tab.url || tab.pendingUrl || "";
  if (/^(chrome|edge|brave|arc|about|moz-extension|chrome-extension|devtools|view-source):/.test(url)) {
    return { error: "browser page, not a web page", url, matched };
  }
  const results = await api.scripting.executeScript({
    target: { tabId: tab.id },
    world: "MAIN",
    func: inspectPage,
    args: [{ screen, scale: req.scale || 1, hint: req.hint || null }],
  });
  const result = results && results[0] && results[0].result;
  if (!result) return { error: "the page didn't answer", url, matched };
  return { matched, ...result };
}

function showState() {
  if (!api.action || !api.action.setBadgeText) return;
  const on = state === "connected";
  api.action.setBadgeText({ text: on ? "on" : "" }).catch?.(() => {});
  if (on && api.action.setBadgeBackgroundColor) api.action.setBadgeBackgroundColor({ color: "#2DA44E" }).catch?.(() => {});
}

// The popup asks how things are going.
api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || !message.type) return;
  if (message.type === "status") {
    sendResponse({ state, url: CRITIQUE, lastError, lastRequestAt, answered, browser: browserName() });
  } else if (message.type === "reconnect") {
    backoff = MIN_BACKOFF;
    if (socket) { try { socket.close(); } catch {} socket = null; }
    connect();
    sendResponse({ ok: true });
  }
});

// Wake up now and then in case Critique started while this worker was asleep.
api.alarms.create("critique-reconnect", { periodInMinutes: 0.5 });
api.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === "critique-reconnect" && state !== "connected") { backoff = MIN_BACKOFF; connect(); }
});
api.runtime.onStartup.addListener(connect);
api.runtime.onInstalled.addListener(connect);

connect();
