#!/usr/bin/env python3
"""replay proxy — the millfolio demo's codegen seam.

The real millfolio app server writes each vault program by POSTing to a configurable
endpoint (`{ANTHROPIC_BASE_URL}/messages`, Anthropic Messages API shape). For the
public demo we point `ANTHROPIC_BASE_URL` at THIS proxy instead of api.anthropic.com,
so the real code is UNCHANGED and has no idea it's a demo — it just gets a program
back. Two modes, decided per request:

  • CACHE HIT  → return the cached program (no upstream call). This is the demo path:
                 curated questions over the fixed synthetic vault always hit.
  • CACHE MISS →
      - capture mode (DEMO_CAPTURE_KEY set): forward to the real Anthropic API,
        store (key → program), return it. Used by `prime-cache.sh` to fill the cache
        with programs the REAL model wrote.
      - replay mode (no capture key): return a friendly fallback program. No public
        traffic ever reaches a paid API.

Cache key = sha256(system + "\\x01" + each message's content) — deterministic for a
given question over the fixed fixture vault, so suggested-question chips (exact text)
always hit. Stdlib only; runs anywhere with python3.

Env:
  DEMO_PORT            listen port (default 8788). The app server uses
                       ANTHROPIC_BASE_URL=http://127.0.0.1:$DEMO_PORT/v1
  REPLAY_CACHE_DIR     cache dir (default: ./cache next to this file)
  DEMO_CAPTURE_KEY     a real Anthropic key → capture misses (priming). Unset = replay.
  ANTHROPIC_UPSTREAM   upstream messages URL (default https://api.anthropic.com/v1/messages)
"""

import json
import os
import hashlib
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.environ.get("REPLAY_CACHE_DIR", os.path.join(HERE, "cache"))
CAPTURE_KEY = os.environ.get("DEMO_CAPTURE_KEY", "").strip()
UPSTREAM = os.environ.get("ANTHROPIC_UPSTREAM", "https://api.anthropic.com/v1/messages")
PORT = int(os.environ.get("DEMO_PORT", "8788"))

# A valid `from vault import *` program for unknown questions — keeps the demo safe
# (no live model call) and on-message.
FALLBACK_PROGRAM = (
    "from vault import *\n"
    "def main() raises:\n"
    "    print_answer(\"This is the millfolio demo over a synthetic vault — try one of \"\n"
    "        \"the suggested questions (how many transactions, biggest transaction, \"\n"
    "        \"total spent, what kinds of files are in my vault).\")\n"
)


def _cache_key(body: dict) -> str:
    h = hashlib.sha256()
    sys = body.get("system") or ""
    if isinstance(sys, list):  # content blocks (prompt-caching: system=[{type,text,cache_control}])
        sys = "".join(b.get("text", "") for b in sys if isinstance(b, dict))
    h.update(sys.encode("utf-8"))
    for m in body.get("messages") or []:
        c = m.get("content")
        if isinstance(c, list):  # content blocks
            c = "".join(b.get("text", "") for b in c if isinstance(b, dict))
        h.update(b"\x01")
        h.update((c or "").encode("utf-8"))
    return h.hexdigest()


def _question_of(body: dict) -> str:
    """Best-effort: the tail of the last user message (for a human-readable index)."""
    msgs = body.get("messages") or []
    if not msgs:
        return ""
    c = msgs[-1].get("content") or ""
    if isinstance(c, list):
        c = "".join(b.get("text", "") for b in c if isinstance(b, dict))
    return c.strip()[-200:]


def _prog_path(key: str) -> str:
    return os.path.join(CACHE_DIR, key + ".mojo")


def _load(key: str):
    p = _prog_path(key)
    if os.path.exists(p):
        with open(p, "r") as f:
            return f.read()
    return None


def _store(key: str, program: str, question: str):
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(_prog_path(key), "w") as f:
        f.write(program)
    idx_path = os.path.join(CACHE_DIR, "index.json")
    idx = {}
    if os.path.exists(idx_path):
        try:
            idx = json.load(open(idx_path))
        except Exception:
            idx = {}
    idx[key] = {"question": question}
    with open(idx_path, "w") as f:
        json.dump(idx, f, indent=2, sort_keys=True)


def _messages_response(program: str, model: str) -> dict:
    """The minimal Anthropic Messages response shape transport._anthropic reads:
    content[0].text (the program), stop_reason, usage.{input,output}_tokens."""
    return {
        "id": "msg_replay",
        "type": "message",
        "role": "assistant",
        "model": model or "claude-demo-replay",
        "content": [{"type": "text", "text": program}],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 0, "output_tokens": 0},
    }


def _forward_upstream(raw: bytes, headers: dict) -> bytes:
    req = urllib.request.Request(UPSTREAM, data=raw, method="POST")
    req.add_header("content-type", "application/json")
    req.add_header("anthropic-version", headers.get("anthropic-version", "2023-06-01"))
    req.add_header("x-api-key", CAPTURE_KEY)
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quieter logs
        pass

    def _send(self, code: int, obj: dict):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", "/healthz"):
            n = len([f for f in os.listdir(CACHE_DIR) if f.endswith(".mojo")]) if os.path.isdir(CACHE_DIR) else 0
            self._send(200, {"ok": True, "mode": "capture" if CAPTURE_KEY else "replay", "cached_programs": n})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/messages"):
            self._send(404, {"type": "error", "error": {"type": "not_found", "message": self.path}})
            return
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw)
        except Exception as e:
            self._send(400, {"type": "error", "error": {"type": "invalid_request_error", "message": str(e)}})
            return

        key = _cache_key(body)
        model = body.get("model", "")
        cached = _load(key)
        if cached is not None:
            print(f"[replay] HIT  {key[:12]}  «{_question_of(body)[:60]}»", flush=True)
            self._send(200, _messages_response(cached, model))
            return

        if CAPTURE_KEY:
            print(f"[replay] MISS {key[:12]} → capturing from upstream  «{_question_of(body)[:60]}»", flush=True)
            try:
                up = _forward_upstream(raw, self.headers)
                upj = json.loads(up)
                # Scan ALL content blocks for text — newer models (claude-sonnet-5)
                # emit a leading `thinking`/`tool_use` block, so content[0] often has no
                # `text` and the old content[0]["text"] captured "" → nothing stored.
                # (Mirrors the same fix in enclave transport._anthropic.)
                prog = "".join(
                    b.get("text", "")
                    for b in (upj.get("content") or [])
                    if isinstance(b, dict) and b.get("type") == "text"
                )
                if prog and upj.get("stop_reason") != "max_tokens":
                    _store(key, prog, _question_of(body))
                # passthrough the real response verbatim (already the right shape)
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(up)))
                self.end_headers()
                self.wfile.write(up)
            except Exception as e:
                self._send(502, {"type": "error", "error": {"type": "api_error", "message": str(e)}})
            return

        print(f"[replay] MISS {key[:12]} → fallback (replay mode)  «{_question_of(body)[:60]}»", flush=True)
        self._send(200, _messages_response(FALLBACK_PROGRAM, model))


def main():
    os.makedirs(CACHE_DIR, exist_ok=True)
    mode = "CAPTURE (priming)" if CAPTURE_KEY else "REPLAY (public-safe)"
    print(f"millfolio demo replay proxy — {mode} — :{PORT}  cache={CACHE_DIR}", flush=True)
    print(f"  point the app server at:  ANTHROPIC_BASE_URL=http://127.0.0.1:{PORT}/v1", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
