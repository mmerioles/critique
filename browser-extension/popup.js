// Shows whether the background worker is talking to Critique.
const api = globalThis.browser ?? globalThis.chrome;
const dot = document.getElementById("dot");
const text = document.getElementById("text");
const hint = document.getElementById("hint");

async function refresh() {
  let status;
  try { status = await api.runtime.sendMessage({ type: "status" }); } catch {}
  if (!status) {
    dot.className = "dot";
    text.textContent = "Not running";
    hint.textContent = "The extension's background worker isn't answering. Reload the extension.";
    return;
  }
  dot.className = "dot " + (status.state === "connected" ? "on" : status.state === "connecting" ? "connecting" : "");
  if (status.state === "connected") {
    text.textContent = "Connected to Critique";
    hint.textContent = status.answered
      ? `Answered ${status.answered} drawing${status.answered === 1 ? "" : "s"} this session.`
      : "Draw around something on a web page and the agent gets its selector, test id and component.";
  } else {
    text.textContent = status.state === "connecting" ? "Connecting…" : "Not connected";
    hint.innerHTML = "Open Critique on this Mac. It listens on <code>" + status.url + "</code>.";
  }
}

document.getElementById("retry").addEventListener("click", async () => {
  try { await api.runtime.sendMessage({ type: "reconnect" }); } catch {}
  setTimeout(refresh, 400);
});

refresh();
setInterval(refresh, 1500);
