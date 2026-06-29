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
from egress import EgressGuard


# ── helpers ──────────────────────────────────────────────────────────────────


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


def _default_codegen_system() -> String:
    """Built-in fallback prompt, used only if the resource file can't be read.
    The model's training predates current Mojo, so it emits removed syntax (`let`,
    `fn`, `alias`, `from pathlib import`). Teach the current dialect + give a
    known-good example to pattern-match. (Static, no private data — safe to send.)
    """
    var s = String(
        "You generate ONE self-contained Mojo program. Output ONLY Mojo code —"
        " no prose, no markdown fences.\n\n"
    )
    s += (
        "Mojo has CHANGED since your training data. Follow these rules"
        " EXACTLY:\n"
    )
    s += (
        "- Use `def`, never `fn` (removed). `def` does NOT imply raising; write"
        " `def main() raises:`.\n"
    )
    s += "- Use `var`, never `let` (removed).\n"
    s += "- Use `comptime`, never `alias` (removed).\n"
    s += (
        "- Stdlib imports need the `std.` prefix (e.g. `from std.os import"
        " ...`). Avoid pathlib — read files with `open()`.\n"
    )
    s += (
        "- No String slicing (`s[a:b]` is invalid). Use `s.split(sep)` and wrap"
        " parts with `String(...)`.\n"
    )
    s += (
        "- `len(x)` for lists; `s.byte_length()` for a String's length;"
        " `String(s.strip())` to trim.\n\n"
    )
    s += (
        "TASK: read the CSV at the literal path __DATA_CSV__ (first row is a"
        " header), compute the requested result, and `print` it. Refer to"
        " columns by their aliases (col_0, col_1, ...).\n\n"
    )
    s += "COMPLETE VALID EXAMPLE — match this exact style and API:\n"
    s += _mock_program()
    return s


def _prompt_path() -> String:
    """Where to load the system prompt from. `PRIVACY_BOX_PROMPT` overrides; otherwise
    `resources/privacy_box-system.md` relative to the install dir (cwd), matching how
    the sandbox templates are resolved (see wiring.mojo)."""
    var override = getenv("PRIVACY_BOX_PROMPT", "")
    if override != "":
        return override
    return String("resources/privacy_box-system.md")


def _codegen_system() -> String:
    """System prompt for the remote (and fallback local) code generator. Loaded at
    runtime from `resources/privacy_box-system.md` so the agent's contract — the
    confidentiality rules, the vault tool API, the Mojo dialect — can be edited
    without recompiling. Falls back to the built-in prompt if the file is absent.
    """
    try:
        with open(_prompt_path(), "r") as f:
            var text = f.read()
            if String(text.strip()).byte_length() > 0:
                return text^
    except:
        pass  # missing/unreadable -> built-in fallback below
    return _default_codegen_system()


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
        # Opt-in streaming path (proves the SSE pipe; a live-UI sink is the next step).
        if getenv("MILLFOLIO_STREAM_CODEGEN", "") != "":
            return self._anthropic_stream(prompt)
        return self._anthropic(prompt)

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
        var body = String('{"model":"') + self.model + '","max_tokens":8192,'
        body += '"system":"' + _json_escape(sys) + '",'
        body += (
            '"messages":[{"role":"user","content":"'
            + _json_escape(prompt)
            + '"}]}'
        )

        var req = Request(
            method="POST",
            url=self.base_url + "/messages",
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("x-api-key", self.api_key)
        req.headers.set("anthropic-version", "2023-06-01")
        req.headers.set("content-type", "application/json")
        var client = HttpClient()
        var resp = client.send(req)
        var v = resp.json()
        var code = _strip_fences(v["content"][0]["text"].string_value())
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
        return Generated(code^, toks)

    def _anthropic_stream(self, prompt: String) raises -> Generated:
        """Streaming codegen — same request as `_anthropic` but `stream:true`, driven
        over a raw TlsStream (flare's HttpClient reads the whole body at once). SSE is
        Anthropic-specific so it lives here, not in the generic client. Parses the
        `content_block_delta` events and accumulates the program. Opt-in via
        $MILLFOLIO_STREAM_CODEGEN. (v1 reads the full body then parses — proves the
        TLS + de-chunk + SSE pipe; a per-delta sink for LIVE UI is the next increment,
        see STREAMING_CODEGEN.md.)"""
        var sys = _codegen_system()
        var body = String('{"model":"') + self.model + '","max_tokens":8192,"stream":true,'
        body += '"system":"' + _json_escape(sys) + '",'
        body += '"messages":[{"role":"user","content":"' + _json_escape(prompt) + '"}]}'

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

        var stream = TlsStream.connect_timeout(host, UInt16(443), TlsConfig(), 120000)
        var wb = wire.as_bytes()
        stream.write_all(Span[UInt8, _](wb))

        # Read the whole response (Connection: close → EOF-delimited).
        var rbuf = List[UInt8](capacity=16384)
        rbuf.resize(16384, 0)
        var raw = List[UInt8](capacity=65536)
        while True:
            var n = stream.read(rbuf.unsafe_ptr(), len(rbuf))
            if n == 0:
                break
            for i in range(n):
                raw.append(rbuf[i])
        stream.close()
        var resp = String(unsafe_from_utf8=Span[UInt8, _](raw))

        # Body after the headers = the SSE stream. We don't explicitly de-frame
        # chunked transfer-encoding: SSE parsing only consumes `data:` lines, and a
        # chunk-size framing line doesn't match that prefix. (A rare chunk boundary
        # that splits a data: line just drops that delta — its JSON parse fails and we
        # skip it. Converting the WHOLE response at once keeps UTF-8 valid.)
        var he = resp.find("\r\n\r\n")
        if he == -1:
            raise Error("codegen stream: malformed response (no header terminator)")
        var sse = String(resp[byte=he + 4 :])

        # Parse the SSE: `data: <json>` lines. content_block_delta → append text;
        # message_delta → stop_reason / output token count.
        var code = String("")
        var toks = 0
        var truncated = False
        var lines = sse.split("\n")
        for li in range(len(lines)):
            var line = String(lines[li]).strip()
            if not line.startswith("data:"):
                continue
            var data = String(String(line[byte=5:]).strip())
            if data == "" or data == "[DONE]":
                continue
            try:
                var ev = loads(data)
                var t = ev["type"].string_value()
                if t == "content_block_delta":
                    code += ev["delta"]["text"].string_value()
                elif t == "message_delta":
                    try:
                        if ev["delta"]["stop_reason"].string_value() == "max_tokens":
                            truncated = True
                    except:
                        pass
                    try:
                        toks += Int(ev["usage"]["output_tokens"].int_value())
                    except:
                        pass
            except:
                pass  # ping / keepalive / non-JSON event line
        if truncated:
            raise Error(
                "codegen truncated: the model hit max_tokens before finishing the"
                " program (stop_reason=max_tokens). Raise max_tokens or simplify."
            )
        return Generated(_strip_fences(code), toks)
