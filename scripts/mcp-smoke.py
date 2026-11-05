#!/usr/bin/env python3 -I
"""Smoke test for `Critique mcp`.

Spawns .build/release/Critique mcp with CRITIQUE_HOME pointed at a temp dir holding one
fake critique, talks JSON-RPC to it over stdio, and checks the shapes of what comes back.

    swift build -c release && python3 -I scripts/mcp-smoke.py [path/to/Critique]
"""
import base64
import json
import os
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".build/release/Critique"
ITEM = "2026-11-04_10-00-00"
TIMEOUT = 20


def png(width=16, height=16, rgb=(255, 59, 48)):
    """A tiny solid-colour PNG, built by hand so the test needs no image library."""
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def write_item(inbox, item_id, notes, shot_file="1-drawing.png", created="2026-11-04T10:00:00Z", project=None):
    folder = inbox / item_id
    folder.mkdir(parents=True)
    (folder / shot_file).write_bytes(png())
    record = {
        "id": item_id,
        "createdAt": created,
        "notes": notes,
        "shots": [{"number": 1, "kind": "drawing", "file": shot_file, "app": "Safari", "element": "button “Sign up”",
                   "region": [10, 20, 100, 40]}],
    }
    if project:
        record["project"] = project
    (folder / "feedback.json").write_text(json.dumps(record))
    (folder / "feedback.md").write_text("# UX feedback\n\n> " + notes + "\n")
    return folder


class Server:
    def __init__(self, env, cwd):
        self.proc = subprocess.Popen([str(BINARY), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=env, cwd=cwd, text=True, bufsize=1)
        self.lines = queue.Queue()
        self.pending = {}
        self.next_id = 1
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def send(self, method, params=None):
        rid = self.next_id
        self.next_id += 1
        self._write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        return rid

    def _write(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def response(self, rid, timeout=TIMEOUT):
        """The full JSON-RPC response with this id, whatever order replies arrive in."""
        deadline = time.monotonic() + timeout
        while rid not in self.pending:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "timed out waiting for response %s" % rid
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty:
                raise AssertionError("timed out waiting for response %s" % rid)
            assert line is not None, "server exited"
            message = json.loads(line)
            assert message.get("jsonrpc") == "2.0", line
            self.pending[message["id"]] = message
        return self.pending.pop(rid)

    def result(self, method, params=None):
        message = self.response(self.send(method, params))
        assert "result" in message, "expected a result, got %s" % json.dumps(message)[:300]
        return message["result"]

    def error(self, method, params=None):
        message = self.response(self.send(method, params))
        assert "error" in message, "expected an error, got %s" % json.dumps(message)[:300]
        return message["error"]

    def call(self, name, args=None):
        return self.result("tools/call", {"name": name, "arguments": args or {}})

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


def blocks(result, kind):
    return [b for b in result["content"] if b["type"] == kind]


def main():
    assert BINARY.exists(), "build first: swift build -c release (%s not found)" % BINARY
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp) / "home"
        inbox = home / "inbox"
        work = Path(tmp) / "project"
        work.mkdir()
        item = write_item(inbox, ITEM, "This button is way too big [#1] and the text is cut off.")

        env = dict(os.environ, CRITIQUE_HOME=str(home))
        server = Server(env, str(work))
        checks = 0

        def ok(label):
            nonlocal checks
            checks += 1
            print("  ok  " + label)

        # initialize + notifications/initialized (no reply) + ping
        init = server.result("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                            "clientInfo": {"name": "smoke", "version": "0"}})
        assert init["protocolVersion"] == "2025-06-18"
        assert "tools" in init["capabilities"] and "resources" in init["capabilities"], init["capabilities"]
        assert init["serverInfo"]["name"] == "critique"
        assert "acknowledge_feedback" in init["instructions"]
        ok("initialize advertises tools + resources")
        server.notify("notifications/initialized")
        assert server.result("ping") == {}
        assert server.lines.empty(), "a notification must get no reply"
        ok("notifications/initialized is silent; ping answers")

        # unknown method / unknown tool are proper errors
        assert server.error("nonsense/method")["code"] == -32601
        assert server.error("tools/call", {"name": "nope", "arguments": {}})["code"] == -32602
        ok("unknown method -32601, unknown tool -32602")

        # tools/list
        tools = {t["name"]: t for t in server.result("tools/list")["tools"]}
        for name in ("get_feedback", "wait_for_feedback", "acknowledge_feedback", "get_image", "list_feedback"):
            assert name in tools, name
            assert tools[name]["inputSchema"]["type"] == "object"
        assert "inline_images" in tools["get_feedback"]["inputSchema"]["properties"]
        assert tools["acknowledge_feedback"]["inputSchema"]["required"] == ["ids"]
        ok("tools/list has the five tools")

        # resources
        templates = server.result("resources/templates/list")["resourceTemplates"]
        assert templates[0]["uriTemplate"] == "critique://inbox/{id}/{file}", templates
        assert "name" in templates[0]
        ok("resources/templates/list")

        resources = {r["uri"]: r for r in server.result("resources/list")["resources"]}
        base = "critique://inbox/%s/" % ITEM
        for name, mime in (("feedback.md", "text/markdown"), ("feedback.json", "application/json"), ("1-drawing.png", "image/png")):
            r = resources[base + name]
            assert r["mimeType"] == mime and r["name"] and r["size"] > 0, r
        ok("resources/list lists the critique's files")

        md = server.result("resources/read", {"uri": base + "feedback.md"})["contents"][0]
        assert md["mimeType"] == "text/markdown" and md["uri"] == base + "feedback.md" and "too big" in md["text"]
        img = server.result("resources/read", {"uri": base + "1-drawing.png"})["contents"][0]
        assert img["mimeType"] == "image/png" and base64.b64decode(img["blob"]) == png() and "text" not in img
        ok("resources/read: text for markdown, blob for png")

        assert server.error("resources/read", {"uri": base + "missing.png"})["code"] == -32002
        assert server.error("resources/read", {"uri": "critique://inbox/../home/feedback.json"})["code"] == -32002
        assert server.error("resources/read", {"uri": base + "../../" + ITEM + "/feedback.json"})["code"] == -32002
        ok("resources/read: missing and traversal uris are -32002")

        # get_feedback: markdown + inline image for the newest + resource links, no mark-on-fetch
        fb = server.call("get_feedback")
        texts = blocks(fb, "text")
        assert "What they said" in texts[0]["text"] and "too big" in texts[0]["text"]
        images = blocks(fb, "image")
        assert len(images) == 1 and images[0]["mimeType"] == "image/jpeg" and base64.b64decode(images[0]["data"])[:2] == b"\xff\xd8"
        links = {l["uri"]: l for l in blocks(fb, "resource_link")}
        link = links[base + "1-drawing.png"]
        assert link["name"] == "1-drawing.png" and link["mimeType"] == "image/png" and link["description"]
        assert base + "feedback.md" not in links
        assert ITEM in texts[-1]["text"] and "acknowledge_feedback" in texts[-1]["text"]
        assert not (item / ".seen").exists(), "get_feedback must not mark items read"
        ok("get_feedback: markdown, one inline jpeg, resource_link, not marked read")

        fb = server.call("get_feedback", {"inline_images": False})
        assert not blocks(fb, "image") and blocks(fb, "resource_link")
        ok("get_feedback inline_images=false is links only")

        fb = server.call("get_feedback", {"id": ITEM})
        assert len(blocks(fb, "image")) == 1
        assert "No feedback" in server.call("get_feedback", {"id": "nope"})["content"][0]["text"]
        ok("get_feedback by id")

        listing = server.call("list_feedback")["content"][0]["text"]
        assert ITEM in listing and "UNREAD" in listing
        ok("list_feedback shows it unread")

        # get_image
        gi = server.call("get_image", {"uri": base + "1-drawing.png", "max_pixels": 8})
        assert blocks(gi, "image")[0]["mimeType"] == "image/jpeg"
        assert server.call("get_image", {"uri": base + "feedback.md"}).get("isError") is True
        ok("get_image inlines one image by uri")

        # acknowledge
        ack = server.call("acknowledge_feedback", {"ids": [ITEM, "bogus"]})["content"][0]["text"]
        assert "Acknowledged 1" in ack and "bogus" in ack, ack
        assert (item / ".seen").exists(), "acknowledge_feedback writes .seen"
        fb = server.call("get_feedback")
        assert "already acknowledged" in fb["content"][0]["text"]
        assert "acknowledged" in server.call("list_feedback")["content"][0]["text"]
        assert server.call("acknowledge_feedback", {}).get("isError") is True
        ok("acknowledge_feedback marks .seen; get_feedback then returns the latest")

        # wait_for_feedback: wakes when a new folder lands (folder first, json later), not for other projects
        rid = server.send("tools/call", {"name": "wait_for_feedback", "arguments": {"timeout_seconds": 12}})
        time.sleep(0.5)
        write_item(inbox, "2026-11-04_10-00-05", "Elsewhere", project={"name": "other", "path": "/nonexistent/other"})
        started = time.monotonic()
        new = "2026-11-04_10-00-10"
        folder = inbox / new
        folder.mkdir()
        (folder / "1-drawing.png").write_bytes(png())
        time.sleep(0.4)  # the folder exists before its feedback.json does
        with open(folder / "feedback.json", "w") as f:
            f.write(json.dumps({"id": new, "createdAt": "2026-11-04T10:00:10Z", "notes": "Second round",
                                "shots": [{"number": 1, "kind": "drawing", "file": "1-drawing.png"}]}))
        wf = server.response(rid)["result"]
        elapsed = time.monotonic() - started
        texts = blocks(wf, "text")
        assert "Second round" in texts[0]["text"] and "Elsewhere" not in json.dumps(wf), texts[0]["text"][:200]
        assert elapsed < 4, "took %.1fs: the watcher should wake well before the 5 s fallback poll" % elapsed
        assert not (folder / ".seen").exists()
        ok("wait_for_feedback woke in %.1fs on a new item, skipped another project's, not marked read" % elapsed)

        wf = server.call("wait_for_feedback", {"timeout_seconds": 1})
        assert "No new feedback" in wf["content"][0]["text"]
        ok("wait_for_feedback times out cleanly")

        server.close()
        print("PASS: %d checks" % checks)


if __name__ == "__main__":
    try:
        main()
    except AssertionError as e:
        print("FAIL: %s" % e)
        sys.exit(1)
