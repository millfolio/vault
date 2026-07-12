"""handlers_apikey — the in-app Anthropic API key settings handlers.

`GET/POST/DELETE /api/settings/apikey`: for native users who never set the
`ANTHROPIC_API_KEY` env var, this persists a key 0600 in the data dir so codegen
picks it up on the next question (no restart). Disabled in the demo (which has
its own replay-engine key handling).

Phase-1B slice 2: pure moves of the `Api.handle_apikey_*` methods to free
functions. None deref `self.st`, so each takes just `req` (or nothing) — the
`self`-qualified helper calls resolve to the already-extracted leaf modules
(`osutil`, `auth`, `apikey`, `httputil`). `server._route` now delegates here.
Behaviour is identical.
"""

from std.os import getenv

from flare.prelude import *

from json import loads

from apikey import apikey_looks_valid, apikey_hint, apikey_status_json
from osutil import _is_demo
from auth import (
    _read_apikey_file,
    _write_apikey_file,
    _clear_apikey_file,
)
from httputil import unauthorized, _cors, _forbidden


def handle_apikey_get() raises -> Response:
    """GET /api/settings/apikey → `{set, hint}`. Reports whether a key is
    available to codegen (the process env OR the persisted store) and, when
    one is stored in-app, a masked `…last4` hint. NEVER returns the full key.
    Disabled in the demo (it has its own replay-engine key handling)."""
    if _is_demo():
        return _forbidden('{"error":"not available in demo"}')
    # A key from the launch-agent env counts as "set" (codegen can reach the
    # model), but there's no stored value to hint — show it as set, no hint.
    var env_key = String(getenv("ANTHROPIC_API_KEY", "").strip())
    var stored = _read_apikey_file()
    var is_set = env_key != "" or stored != ""
    var hint = apikey_hint(stored) if stored != "" else String("")
    return _cors(ok_json(apikey_status_json(is_set, hint)))


def handle_apikey_post(req: Request) raises -> Response:
    """POST /api/settings/apikey {key} → persist the key 0600 in the data dir
    so codegen picks it up on the next question (no restart). An empty key
    clears the store (same as DELETE). Validated with a minimal sanity gate;
    never logged or echoed back in full — only a masked hint is returned.
    Disabled in the demo."""
    if _is_demo():
        return _forbidden('{"error":"not available in demo"}')
    var key: String
    try:
        var j = loads(req.text())
        key = String(j["key"].string_value().strip())
    except:
        return _cors(bad_request('{"error":"expected {\\"key\\":\\"…\\"}"}'))
    if key == "":
        return handle_apikey_delete()  # empty → clear
    if not apikey_looks_valid(key):
        return _cors(
            bad_request('{"error":"that doesn\'t look like an API key"}')
        )
    _write_apikey_file(key)
    return _cors(ok_json(apikey_status_json(True, apikey_hint(key))))


def handle_apikey_delete() raises -> Response:
    """DELETE /api/settings/apikey (or POST {key:""}) → clear the stored key.
    Codegen reverts to the process env / local-only mode. Disabled in demo."""
    if _is_demo():
        return _forbidden('{"error":"not available in demo"}')
    _clear_apikey_file()
    var env_key = String(getenv("ANTHROPIC_API_KEY", "").strip())
    return _cors(ok_json(apikey_status_json(env_key != "", String(""))))
