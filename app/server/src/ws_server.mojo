"""ws_server — streaming Veilens chat over WebSocket (flare.ws).

Increment 4 of the streaming protocol (see ../STREAMING.md). A WebSocket endpoint
that runs the vault pipeline step by step, streaming a `status`/`debug` event for
each stage and gating the sandbox run on the user's approval — the full workflow
panel. One WS connection = one chat session:

    client → {"type":"ask","text":...}
    server → status/debug per stage; an approval-request before the run
    client → {"type":"approve"} | {"type":"reject"}
    server → status/debug for the run; final message; close

Events are ServerEvent JSON, one per text frame (see ../../protocol/events.ts).

flare's WS handler is a THIN (non-capturing) function, so the handler builds the
orchestrator per connection — fine for a local single-user server.

    pixi run build-ws   # -> build/veilens-ws, WebSocket on 127.0.0.1:10001
"""

from flare.ws import WsServer, WsConnection, WsFrame, WsOpcode, WsCloseCode
from flare.net import SocketAddr

from settings import load_config
from wiring import build_vault_orchestrator
from vaultcfg import vault_dir as resolve_vault_dir
from json import loads

# The static web UI is served by veilens-server on :10000; the WS stream gets its
# own port (flare can't multiplex static-HTTP + WebSocket on one listener).
comptime PORT = 10001


def _json_escape(s: String) -> String:
    """Quote + escape `s` as a JSON string (control chars dropped to spaces)."""
    var out = String('"')
    for cp in s.codepoints():
        var c = Int(cp)
        if c == 34:
            out += '\\"'
        elif c == 92:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += " "
        else:
            out += chr(c)
    out += '"'
    return out


def _field(body: String, key: String) -> String:
    """Pull a top-level string field out of a JSON message (empty on failure)."""
    try:
        var j = loads(body)
        return j[key].string_value()
    except:
        return String("")


def _status(step: String, label: String, state: String) -> String:
    return (
        '{"type":"status","stepId":'
        + _json_escape(step)
        + ',"label":'
        + _json_escape(label)
        + ',"state":'
        + _json_escape(state)
        + "}"
    )


def _debug(step: String, title: String, body: String, language: String) -> String:
    return (
        '{"type":"debug","stepId":'
        + _json_escape(step)
        + ',"title":'
        + _json_escape(title)
        + ',"body":'
        + _json_escape(body)
        + ',"language":'
        + _json_escape(language)
        + "}"
    )


def _approval(step: String, label: String, body: String) -> String:
    return (
        '{"type":"approval-request","stepId":'
        + _json_escape(step)
        + ',"label":'
        + _json_escape(label)
        + ',"payload":{"title":'
        + _json_escape("Sandboxed run — reads your real data locally, no network")
        + ',"body":'
        + _json_escape(body)
        + ',"language":"mojo"}}'
    )


def _message(text: String) -> String:
    return (
        '{"type":"message","id":"msg","role":"assistant","text":'
        + _json_escape(text)
        + "}"
    )


def _error(text: String) -> String:
    return '{"type":"error","message":' + _json_escape(text) + "}"


def on_connect(mut conn: WsConnection) raises:
    """One chat session: stream the vault pipeline with status/debug + an approval
    gate before the run."""
    var frame = conn.recv()
    if frame.opcode == WsOpcode.CLOSE:
        return
    var question = _field(frame.text_payload(), "text")
    if question == "":
        conn.send_text(_error("empty or malformed ask"))
        conn.close(WsCloseCode.NORMAL)
        return

    try:
        var cfg = load_config()
        var vault_dir = resolve_vault_dir()
        var orch = build_vault_orchestrator(cfg, vault_dir)

        # 1. Aliased manifest (the only thing the frontier model sees).
        conn.send_text(_status("manifest", "Aliasing vault manifest", "running"))
        var manifest = orch.vault_manifest(vault_dir)
        conn.send_text(_debug("manifest", "Frontier-safe manifest (aliases only)", manifest, "text"))
        conn.send_text(_status("manifest", "Aliasing vault manifest", "done"))

        # 2. The model writes the program.
        conn.send_text(_status("codegen", "Writing the program", "running"))
        var code = orch.vault_codegen(question, manifest)
        conn.send_text(_debug("codegen", "Generated program", code, "mojo"))
        conn.send_text(_status("codegen", "Writing the program", "done"))

        # 3. Approval gate — the blocking recv() IS the pause.
        conn.send_text(_status("run", "Run the generated program over your vault?", "awaiting-approval"))
        conn.send_text(_approval("run", "Run the generated program over your vault?", code))
        var decision = conn.recv()
        if decision.opcode == WsOpcode.CLOSE or _field(decision.text_payload(), "type") != "approve":
            conn.send_text(_status("run", "Run rejected", "error"))
            conn.send_text(_message("Okay — I won't run that. Tell me how you'd like to adjust it."))
            conn.close(WsCloseCode.NORMAL)
            return

        # 4. Compile + run in the loopback sandbox over the real data.
        conn.send_text(_status("run", "Compiling & running in sandbox", "running"))
        orch.vault_build(code)
        var reply = orch.vault_run(vault_dir)
        conn.send_text(_status("run", "Compiling & running in sandbox", "done"))
        conn.send_text(_message(reply))
    except e:
        conn.send_text(_error(String(e)))
    conn.close(WsCloseCode.NORMAL)


def main() raises:
    print("veilens ws server on ws://127.0.0.1:", PORT, "  (flare.ws)", sep="")
    var srv = WsServer.bind(SocketAddr.localhost(UInt16(PORT)))
    srv.serve(on_connect)
