"""Transport — HTTP to the two models over flare, with the EgressGuard on the remote path.

privacy_box's `pi-ai`-equivalent layer (PRIOR-ART.md): the one place network I/O
happens, so the one place egress policy is enforced. Now pure Mojo over flare's
HttpClient (no curl/python), parsing responses with flare's `Response.json()`.

Two clients, deliberately asymmetric:
  - LocalClient  -> the on-device model via the `inference-server` engine,
                    OpenAI /chat/completions over plain HTTP (127.0.0.1). No egress
                    guard: it never leaves the machine.
  - RemoteClient -> the frontier model (Anthropic Messages API, HTTPS). EVERY
                    message clears the EgressGuard before it touches the socket.

MOCK path: when ANTHROPIC_API_KEY is unset or PRIVACY_BOX_MOCK is set, codegen returns
a canned program so the pipeline runs offline.
"""

from std.os import getenv
from flare.http import HttpClient, Request
from flare.tls import TlsStream, TlsConfig
from json import loads
from logging import log
from egress import EgressGuard
from vaultcfg import resource_path
from codegen_cache import (
    codegen_cache_enabled,
    codegen_cache_dir,
    stable_hash_hex,
    codegen_cache_read,
    codegen_cache_write,
)


# Read timeout for the remote (frontier) model call. A dropped connection (e.g. you
# walk out of the café mid-request) leaves a half-open socket that never delivers a
# byte or a FIN; without a read timeout the codegen read blocks forever (the "Writing
# the program 32:45" hang). 5 minutes tolerates a genuinely slow response while
# aborting a truly dead link. Applies to both the streaming + non-streaming paths.
comptime REMOTE_READ_TIMEOUT_MS = 300000


# ── helpers ──────────────────────────────────────────────────────────────────


trait DeltaSink(Movable):
    """Receives the codegen text as it streams in. The app server implements this to
    emit a live status/debug event per delta; CLI/other callers use `NullSink`. (A
    trait, not a closure — this Mojo nightly removed `escaping`/nested `fn`.)"""

    def on_delta(mut self, text: String) raises:
        ...


struct NullSink(DeltaSink, Movable):
    """A sink that drops every delta — for non-streaming callers."""

    def on_delta(mut self, text: String) raises:
        pass


def _find_byte(buf: List[UInt8], val: Int, start: Int) -> Int:
    """First index ≥ `start` in `buf` holding byte `val`, or -1."""
    var i = start
    while i < len(buf):
        if Int(buf[i]) == val:
            return i
        i += 1
    return -1


def _find_crlfcrlf(buf: List[UInt8], start: Int) -> Int:
    """First index ≥ `start` of a `\\r\\n\\r\\n` (header terminator), or -1."""
    var i = start
    while i + 3 < len(buf):
        if (
            Int(buf[i]) == 13
            and Int(buf[i + 1]) == 10
            and Int(buf[i + 2]) == 13
            and Int(buf[i + 3]) == 10
        ):
            return i
        i += 1
    return -1


def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out


def _json_escape(s: String) raises -> String:
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String('"'), String('\\"'))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    o = _replace_all(o, String("\t"), String("\\t"))
    return o


def _strip_fences(var s: String) raises -> String:
    """If the model wrapped code in a ```...``` block, return the inside (minus
    the optional leading language tag). String has no slicing, so split + rejoin.
    """
    if s.find("```") == -1:
        return s^
    var parts = s.split("```")
    if len(parts) < 2:
        return s^
    var block = String(parts[1])
    if block.find("\n") == -1:
        return block^
    var lines = block.split("\n")
    var out = String("")
    for i in range(1, len(lines)):  # drop the language-tag line
        if i > 1:
            out += "\n"
        out += String(lines[i])
    return out^


def _mock_program() -> String:
    """Canned 'generated' program: count non-empty data rows in the CSV at the
    `__DATA_CSV__` placeholder (the orchestrator injects the real path)."""
    var s = String("def main() raises:\n")
    s += "    var text: String\n"
    s += '    with open("__DATA_CSV__", "r") as f:\n'
    s += "        text = f.read()\n"
    s += '    var lines = text.split("\\n")\n'
    s += "    var count = 0\n"
    s += "    for i in range(1, len(lines)):\n"
    s += "        var ln = String(String(lines[i]).strip())\n"
    s += "        if ln.byte_length() > 0:\n"
    s += "            count += 1\n"
    s += '    print("ROW_COUNT=", count)\n'
    return s


def _prompt_path() raises -> String:
    """Where to load the system prompt from. `PRIVACY_BOX_PROMPT` (an absolute path)
    overrides; otherwise `resources/privacy_box-system.md` resolved under
    `PRIVACY_BOX_HOME` (every launcher sets it — see resource_path). NEVER cwd.
    """
    var override = getenv("PRIVACY_BOX_PROMPT", "")
    if override != "":
        return override
    return resource_path(String("resources/privacy_box-system.md"))


def _codegen_system() raises -> String:
    """System prompt for the frontier code generator. Loaded at runtime from
    `resources/privacy_box-system.md` (resolved by ABSOLUTE path — PRIVACY_BOX_HOME /
    PRIVACY_BOX_PROMPT, never cwd) so the agent's contract — the confidentiality rules,
    the vault tool API, the Mojo dialect — can be edited without recompiling.

    RAISES if the prompt can't be read or is empty — there is NO built-in stub
    fallback. A silent fallback previously masked a misconfigured path and shipped a
    wrong 'read __DATA_CSV__ and print()' stub prompt to the model; failing loud makes
    that a fast, obvious error instead of silently-degraded codegen."""
    var path = _prompt_path()
    var text: String
    with open(path, "r") as f:
        text = f.read()
    if String(text.strip()).byte_length() == 0:
        raise Error("codegen system prompt is empty: " + path)
    return text^


struct ChatMessage(Copyable, Movable):
    var role: String  # "system" | "user" | "assistant"
    var content: String

    def __init__(out self, var role: String, var content: String):
        self.role = role^
        self.content = content^


struct LocalClient(Movable):
    """Local model via inference-server, OpenAI /chat/completions over plain HTTP.
    """

    var base_url: String  # e.g. http://127.0.0.1:8000/v1
    var model: String

    def __init__(out self, var base_url: String, var model: String):
        self.base_url = base_url^
        self.model = model^

    def chat(self, messages: List[ChatMessage]) raises -> String:
        """POST the messages and return the assistant content. Local only — no
        egress guard. Requires inference-server running."""
        var body = (
            String('{"model":"')
            + self.model
            + '","max_tokens":4096,"messages":['
        )
        for i in range(len(messages)):
            if i > 0:
                body += ","
            body += '{"role":"' + messages[i].role
            body += '","content":"' + _json_escape(messages[i].content) + '"}'
        body += "]}"

        var req = Request(
            method="POST",
            url=self.base_url + "/chat/completions",
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("content-type", "application/json")
        var client = HttpClient()
        var resp = client.send(req)
        return resp.json()["choices"][0]["message"]["content"].string_value()

    def codegen(self, messages: List[ChatMessage]) raises -> String:
        """Local model AS code generator — used when the remote budget is depleted.
        Trusted + free; no egress guard. Prepends the current-Mojo system prompt so
        the local model writes valid Mojo; strips code fences."""
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("system"), _codegen_system()))
        for m in messages:
            msgs.append(ChatMessage(m.role.copy(), m.content.copy()))
        return _strip_fences(self.chat(msgs))

    def fix_code(self, code: String, errors: String) raises -> String:
        """Local model fixes failing code — used when the remote budget is depleted.
        """
        var prompt = (
            String(
                "The Mojo program below FAILED. Fix it and output ONLY the"
                " corrected, complete Mojo program.\n\nERRORS:\n"
            )
            + errors
            + "\n\nPROGRAM:\n"
            + code
        )
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("system"), _codegen_system()))
        msgs.append(ChatMessage(String("user"), prompt))
        return _strip_fences(self.chat(msgs))


struct Generated(Movable):
    """A code-generation result: the code + the token cost (from the remote API's
    usage; 0 for mock). The orchestrator charges the Budget by `tokens`."""

    var code: String
    var tokens: Int

    def __init__(out self, var code: String, tokens: Int):
        self.code = code^
        self.tokens = tokens


struct RemoteClient(Movable):
    """Frontier model (Anthropic Messages API, HTTPS). The guard gates the outbound
    path — enforced here, not left to callers, so it cannot be bypassed."""

    var base_url: String  # e.g. https://api.anthropic.com/v1
    var api_key: String
    var model: String
    var mock: Bool  # force the canned program (offline) instead of a real call
    var guard: EgressGuard

    def __init__(
        out self,
        var base_url: String,
        var api_key: String,
        var model: String,
        mock: Bool,
        var guard: EgressGuard,
    ):
        self.base_url = base_url^
        self.api_key = api_key^
        self.model = model^
        self.mock = mock
        self.guard = guard^

    def codegen(self, messages: List[ChatMessage]) raises -> Generated:
        """Each message must clear the EgressGuard first (fails closed). Returns the
        generated code + token cost. MOCK when configured or no key present."""
        var prompt = String("")
        for m in messages:
            var checked = self.guard.check(m.content)  # raises -> aborts send
            prompt += m.role + ": " + checked + "\n"

        if self.mock or self.api_key == "":
            return Generated(_mock_program(), prompt.byte_length() // 4 + 300)
        return self._anthropic(prompt)

    def codegen_stream[
        S: DeltaSink
    ](self, messages: List[ChatMessage], mut sink: S) raises -> Generated:
        """Like `codegen` but STREAMS the program via `sink` (live). Same EgressGuard
        gate. MOCK / no key falls back to the canned program (no streaming)."""
        var prompt = String("")
        for m in messages:
            var checked = self.guard.check(m.content)  # raises -> aborts send
            prompt += m.role + ": " + checked + "\n"
        if self.mock or self.api_key == "":
            return Generated(_mock_program(), prompt.byte_length() // 4 + 300)
        return self._anthropic_stream(prompt, sink)

    def fix_code(self, code: String, errors: String) raises -> Generated:
        """Ask the remote model to fix code that failed (compile or runtime).
        Operates ONLY on ALIASED code + aliased errors (no real data/names) — still
        routed through the EgressGuard (fails closed). Offline (mock / no key):
        returns the code unchanged at 0 cost."""
        var prompt = String(
            "The Mojo program below FAILED. Fix it and output ONLY the"
            " corrected, complete Mojo program.\n\nERRORS:\n"
        )
        prompt += errors + "\n\nPROGRAM:\n" + code
        var checked = self.guard.check(prompt)  # raises -> aborts the send
        if self.mock or self.api_key == "":
            return Generated(code.copy(), 0)
        return self._anthropic(checked)

    def _anthropic(self, prompt: String) raises -> Generated:
        var sys = _codegen_system()
        # 8192 (was 2048): a fuller program — search + per-chunk ask_local loop with
        # progress(), parse_amount/iso_date, both branches — plus any reasoning the
        # model emits can exceed 2048 and get cut mid-line, which then never compiles
        # (and every fix attempt re-truncated at the same cap).
        #
        # `system` is an ARRAY of content blocks (not a bare string) with a
        # `cache_control:{type:ephemeral}` breakpoint on the block, so Anthropic
        # prompt-caches the large, stable system prompt (well over the 1024-token
        # minimum) — the ~41% server-side lever. The aliased manifest + question
        # ride in the user message AFTER it and vary per request, so only the
        # system prefix is cached (the manifest can't be split out cleanly here).
        var body = String('{"model":"') + self.model + '","max_tokens":8192,'
        body += '"system":[{"type":"text","text":"' + _json_escape(sys)
        body += '","cache_control":{"type":"ephemeral"}}],'
        body += (
            '"messages":[{"role":"user","content":"'
            + _json_escape(prompt)
            + '"}]}'
        )

        # ── disk cache (read) ─────────────────────────────────────────────────
        # Key on the FINAL body bytes (built above, WITH the cache_control markers,
        # which are stable) so a hit/miss is consistent with what's actually sent.
        # The body embeds the model + system + question, so the key covers them all.
        var use_cache = (not self.mock) and codegen_cache_enabled()
        var cdir = String("")
        var ckey = String("")
        if use_cache:
            cdir = codegen_cache_dir()
            if cdir != "":
                ckey = stable_hash_hex(body)
                var hit = codegen_cache_read(cdir, ckey)
                if hit:
                    log(
                        "• codegen cache hit ("
                        + ckey
                        + ") — reusing the saved program, skipping the API call"
                    )
                    # Cost 0: no network, no egress, no token spend on a hit.
                    return Generated(hit.value().copy(), 0)

        var req = Request(
            method="POST",
            url=self.base_url + "/messages",
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("x-api-key", self.api_key)
        req.headers.set("anthropic-version", "2023-06-01")
        req.headers.set("content-type", "application/json")
        var client = HttpClient()
        # Bound the body read: if the response stalls (a dropped connection — the
        # network vanished mid-generation), fail after REMOTE_READ_TIMEOUT_MS instead
        # of hanging forever. A real slow codegen still lands (data arrives well
        # inside the window); only silence this long means the link is gone.
        client.set_recv_timeout(REMOTE_READ_TIMEOUT_MS)
        var resp = client.send(req)
        var v = resp.json()
        # Scan the content blocks for the TEXT block(s) — newer models (e.g.
        # claude-sonnet-5) can put a `thinking` / `tool_use` block first, so we can't
        # assume content[0] is the text (that raised a cryptic "Key not found: text").
        # If there's no text at all, surface the API error message (bad model id, no
        # access, rate limit) instead of a key error.
        var raw = String("")
        var nblocks: Int
        try:
            nblocks = v["content"].array_count()
        except:
            nblocks = 0
        for bi in range(nblocks):
            try:
                var block = v["content"][bi]
                if block["type"].string_value() == "text":
                    raw += block["text"].string_value()
            except:
                continue
        if raw.byte_length() == 0:
            var apierr: String
            try:
                apierr = v["error"]["message"].string_value()
            except:
                apierr = String("")
            if apierr != "":
                raise Error("remote model API error: " + apierr)
            raise Error(
                "remote model returned no text content — check remote_model"
                " (the model id) and that your API key has access (see the"
                " server log for the raw response)."
            )
        var code = _strip_fences(raw)
        # If the model hit the token cap the program is incomplete (cut mid-line),
        # which never compiles — and every fix attempt would re-truncate. Fail with a
        # clear message instead of silently looping the compile/fix on a partial file.
        var truncated: Bool
        try:
            truncated = v["stop_reason"].string_value() == "max_tokens"
        except:
            truncated = False
        if truncated:
            raise Error(
                "codegen truncated: the model hit max_tokens before finishing"
                " the program (stop_reason=max_tokens). Raise max_tokens or"
                " simplify the task."
            )
        var toks: Int
        try:
            toks = Int(v["usage"]["input_tokens"].int_value()) + Int(
                v["usage"]["output_tokens"].int_value()
            )
        except:
            toks = 0

        # Surface the server-side prompt-cache usage so the prefix cache is visible.
        try:
            var cw = Int(v["usage"]["cache_creation_input_tokens"].int_value())
            var cr = Int(v["usage"]["cache_read_input_tokens"].int_value())
            if cw > 0 or cr > 0:
                log(
                    "• prompt cache: "
                    + String(cr)
                    + " read / "
                    + String(cw)
                    + " written (input tokens)"
                )
        except:
            pass

        # ── disk cache (write) ────────────────────────────────────────────────
        # Only on SUCCESS: HTTP 200 got us here, `code` is non-empty and not
        # truncated. Best-effort — a write failure can't break codegen.
        if use_cache and cdir != "" and code.byte_length() > 0:
            codegen_cache_write(
                cdir, ckey, self.model, body.byte_length(), code
            )
        return Generated(code^, toks)

    def _anthropic_stream[
        S: DeltaSink
    ](self, prompt: String, mut sink: S) raises -> Generated:
        """Streaming codegen — same request as `_anthropic` but `stream:true`, driven
        over a raw TlsStream (flare's HttpClient reads the whole body at once). SSE is
        Anthropic-specific so it lives here. Parses `content_block_delta` events as the
        bytes arrive, calling `sink.on_delta(text)` per chunk (LIVE) and accumulating
        the program. Byte-level line extraction keeps UTF-8 valid across read
        boundaries (a multibyte codepoint can't span the `\\n` we split on)."""
        var sys = _codegen_system()
        var body = (
            String('{"model":"')
            + self.model
            + '","max_tokens":8192,"stream":true,'
        )
        # `system` as a content-block array with a cache_control breakpoint (see
        # _anthropic): Anthropic prompt-caches the stable system prefix.
        body += '"system":[{"type":"text","text":"' + _json_escape(sys)
        body += '","cache_control":{"type":"ephemeral"}}],'
        body += (
            '"messages":[{"role":"user","content":"'
            + _json_escape(prompt)
            + '"}]}'
        )

        # ── disk cache (read) ─────────────────────────────────────────────────
        # Key on the FINAL body bytes (incl. "stream":true + the cache_control
        # markers). On a hit, replay the saved program to the sink once and return
        # — no TLS connect, no egress, no token spend.
        var use_cache = (not self.mock) and codegen_cache_enabled()
        var cdir = String("")
        var ckey = String("")
        if use_cache:
            cdir = codegen_cache_dir()
            if cdir != "":
                ckey = stable_hash_hex(body)
                var hit = codegen_cache_read(cdir, ckey)
                if hit:
                    var prog = hit.value().copy()
                    log(
                        "• codegen cache hit ("
                        + ckey
                        + ") — replaying the saved program, skipping the API"
                        " call"
                    )
                    sink.on_delta(
                        prog
                    )  # LIVE: surface the whole program at once
                    return Generated(prog^, 0)

        # base_url e.g. https://api.anthropic.com/v1 → host `api.anthropic.com`,
        # request target `/v1/messages`.
        var after = String(self.base_url.split("://")[1])
        var segs = after.split("/")
        var host = String(segs[0])
        var target = String("")
        for i in range(1, len(segs)):
            target += "/" + String(segs[i])
        target += "/messages"

        var wire = String("POST ") + target + " HTTP/1.1\r\n"
        wire += "Host: " + host + "\r\n"
        wire += "x-api-key: " + self.api_key + "\r\n"
        wire += "anthropic-version: 2023-06-01\r\n"
        wire += "content-type: application/json\r\n"
        wire += "accept: text/event-stream\r\n"
        wire += "content-length: " + String(body.byte_length()) + "\r\n"
        wire += "connection: close\r\n\r\n"
        wire += body

        var stream = TlsStream.connect_timeout(
            host, UInt16(443), TlsConfig(), 120000
        )
        # Bound each streamed read: a dropped connection (no more SSE bytes) fails
        # after REMOTE_READ_TIMEOUT_MS of silence instead of hanging forever. Normal
        # streaming delivers tokens continuously, well inside the window.
        stream.set_recv_timeout(REMOTE_READ_TIMEOUT_MS)
        var wb = wire.as_bytes()
        stream.write_all(Span[UInt8, _](wb))

        # Read INCREMENTALLY (Connection: close → EOF-delimited). Skip the response
        # headers (\r\n\r\n) once, then drain complete SSE lines as bytes arrive. We
        # don't de-frame chunked transfer-encoding: SSE parsing only consumes `data:`
        # lines, so chunk-size framing lines are ignored.
        var rbuf = List[UInt8](capacity=16384)
        rbuf.resize(16384, 0)
        var buf = List[UInt8](
            capacity=65536
        )  # received bytes not yet line-consumed
        var consumed = 0
        var headers_done = False
        var code = String("")
        var toks = 0
        var truncated = False
        while True:
            var n = stream.read(rbuf.unsafe_ptr(), len(rbuf))
            if n == 0:
                break
            for i in range(n):
                buf.append(rbuf[i])
            if not headers_done:
                var he = _find_crlfcrlf(buf, consumed)
                if he == -1:
                    continue
                consumed = he + 4
                headers_done = True
            while True:
                var nl = _find_byte(buf, 10, consumed)  # '\n'
                if nl == -1:
                    break
                var end = nl
                if (
                    end > consumed and Int(buf[end - 1]) == 13
                ):  # strip trailing '\r'
                    end -= 1
                var line = String(
                    String(
                        unsafe_from_utf8=Span[UInt8, _](buf[consumed:end])
                    ).strip()
                )
                consumed = nl + 1
                if not line.startswith("data:"):
                    continue
                var data = String(String(line[byte=5:]).strip())
                if data == "" or data == "[DONE]":
                    continue
                try:
                    var ev = loads(data)
                    var t = ev["type"].string_value()
                    if t == "content_block_delta":
                        var txt = ev["delta"]["text"].string_value()
                        code += txt
                        sink.on_delta(txt)  # LIVE: surface the chunk
                    elif t == "message_delta":
                        try:
                            if (
                                ev["delta"]["stop_reason"].string_value()
                                == "max_tokens"
                            ):
                                truncated = True
                        except:
                            pass
                        try:
                            toks += Int(
                                ev["usage"]["output_tokens"].int_value()
                            )
                        except:
                            pass
                except:
                    pass  # ping / keepalive / non-JSON event line
        stream.close()
        if truncated:
            raise Error(
                "codegen truncated: the model hit max_tokens before finishing"
                " the program (stop_reason=max_tokens). Raise max_tokens or"
                " simplify."
            )
        var program = _strip_fences(code)
        # ── disk cache (write) ────────────────────────────────────────────────
        # Reached only on SUCCESS (stream drained, not truncated). Best-effort.
        if use_cache and cdir != "" and program.byte_length() > 0:
            codegen_cache_write(
                cdir, ckey, self.model, body.byte_length(), program
            )
        return Generated(program^, toks)
