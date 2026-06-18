"""ws_server — streaming Veilens chat over WebSocket (flare.ws).

Increment 3 of the streaming protocol (see ../STREAMING.md). A WebSocket endpoint
that runs the vault task and streams events to the client. This increment emits a
`status` (running -> done/error) plus the final `message`; mid-run `debug` and the
`approval-request` gate arrive with the orchestrator EventSink (increment 4).

One WS connection = one chat session: the client sends an `ask` frame
(`{"type":"ask","text":...}`), the server streams ServerEvent JSON frames (one per
text frame; see ../../protocol/events.ts), then closes.

flare's WS handler is a THIN (non-capturing) function, so the handler builds the
orchestrator per connection — fine for a local single-user server; hoisting to
shared state is a later optimization.

    pixi run build-ws   # -> build/veilens-ws, WebSocket on 127.0.0.1:10000
"""

from flare.ws import WsServer, WsConnection, WsFrame, WsOpcode, WsCloseCode
from flare.net import SocketAddr

from settings import load_config
from wiring import build_vault_orchestrator
from vaultcfg import vault_dir as resolve_vault_dir
from json import loads

comptime PORT = 10000


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


def _ask_text(body: String) -> String:
    """Pull `text` out of an `ask` message (empty on any failure)."""
    try:
        var j = loads(body)
        return j["text"].string_value()
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


def _message(text: String) -> String:
    return (
        '{"type":"message","id":"msg","role":"assistant","text":'
        + _json_escape(text)
        + "}"
    )


def _error(text: String) -> String:
    return '{"type":"error","message":' + _json_escape(text) + "}"


def on_connect(mut conn: WsConnection) raises:
    """Handle one chat session: read the `ask`, stream status + the answer."""
    var frame = conn.recv()
    if frame.opcode == WsOpcode.CLOSE:
        return
    var question = _ask_text(frame.text_payload())
    if question == "":
        conn.send_text(_error("empty or malformed ask"))
        conn.close(WsCloseCode.NORMAL)
        return

    conn.send_text(_status("answer", "Answering over your vault", "running"))
    try:
        var cfg = load_config()
        var vault_dir = resolve_vault_dir()
        var orch = build_vault_orchestrator(cfg, vault_dir)
        var reply = orch.run_vault_task(question, vault_dir)
        conn.send_text(_status("answer", "Answering over your vault", "done"))
        conn.send_text(_message(reply))
    except e:
        conn.send_text(_status("answer", "Answering over your vault", "error"))
        conn.send_text(_error(String(e)))
    conn.close(WsCloseCode.NORMAL)


def main() raises:
    print("veilens ws server on ws://127.0.0.1:", PORT, "  (flare.ws)", sep="")
    var srv = WsServer.bind(SocketAddr.localhost(UInt16(PORT)))
    srv.serve(on_connect)
