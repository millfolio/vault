"""handlers_vaults — the multi-vault registry HTTP surface.

The UI's vault switcher drives this. Switching is RESTART-SCOPED (see `vaults.mojo`):
selecting a vault persists the choice; the running process keeps serving the vault
it booted on until restarted. `GET /api/vaults` reports both (`active` = selected,
`running` = booted, `pendingRestart` when they differ) so the client shows a
"restart to apply" prompt — the same pattern as a version change.

  • GET  /api/vaults          — the registry + active/running + pendingRestart.
  • POST /api/vaults/select   — {id} → mark a vault active (takes effect on restart).
  • POST /api/vaults/add      — {name, source} → register a folder as a new vault.
  • POST /api/vaults/remove   — {id} → drop a vault (data left on disk; never "main").
  • POST /api/vaults/add-demo — register + fetch the hosted sample vault, isolated.

Disabled in the public demo (a single fixed vault) — every handler 401s there.
"""

from std.os import getenv
from std.os.path import isdir
from std.ffi import external_call

from flare.prelude import *

from json import loads

from osutil import _is_demo, _cstr
from httputil import unauthorized, _cors
from events import json_escape
import vaults


def _restart_app_server_soon():
    """Ask launchd to restart THIS app-server agent (me.millfolio.appserver) after a
    short delay — long enough to flush the HTTP response first. Applying a vault
    switch needs a restart (the boot hook re-reads the active vault); doing it here
    means the user never has to hunt for a restart, on any surface. The engine
    (a separate agent) stays up, so only the fast app server bounces. No-op off
    launchd (kickstart just fails into /dev/null)."""
    var uid = Int(external_call["getuid", UInt32]())
    var cmd = (
        String("(sleep 1; launchctl kickstart -k gui/")
        + String(uid)
        + "/me.millfolio.appserver) >/dev/null 2>&1 &"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()


def handle_vaults_list() raises -> Response:
    """GET /api/vaults → {active, running, pendingRestart, vaults:[{id,name,source,active}]}.
    """
    if _is_demo():
        return _cors(unauthorized('{"error":"vaults are fixed in the demo"}'))
    return _cors(ok_json(vaults.registry_json()))


def handle_vaults_select(req: Request) raises -> Response:
    """POST /api/vaults/select {id} → make a registered vault active. The switch
    lands on the next server start; response carries pendingRestart=true so the UI
    prompts a restart."""
    if _is_demo():
        return _cors(unauthorized('{"error":"vaults are fixed in the demo"}'))
    var id: String
    try:
        id = String(loads(req.text())["id"].string_value())
    except:
        return _cors(bad_request('{"error":"expected {id}"}'))
    if id == "":
        return _cors(bad_request('{"error":"empty id"}'))
    if not vaults.set_active(id):
        return _cors(bad_request('{"error":"unknown vault"}'))
    # Apply the switch by restarting the app server (the boot hook re-reads the
    # active vault). Skip when we're already running that vault (no-op switch).
    var restarting = id != vaults.running_vault_id()
    if restarting:
        _restart_app_server_soon()
    return _cors(
        ok_json(
            '{"ok":true,"active":'
            + json_escape(id)
            + ',"restarting":'
            + ("true" if restarting else "false")
            + "}"
        )
    )


def handle_vaults_add(req: Request) raises -> Response:
    """POST /api/vaults/add {name, source} → register a folder as a new vault. The
    source must be an existing directory. Does NOT switch to it or index it (that's
    a follow-up select+restart, then the folder indexes on first use)."""
    if _is_demo():
        return _cors(unauthorized('{"error":"vaults are fixed in the demo"}'))
    var name: String
    var source: String
    try:
        var v = loads(req.text())
        name = String(v["name"].string_value())
        source = String(v["source"].string_value())
    except:
        return _cors(bad_request('{"error":"expected {name, source}"}'))
    if name.strip() == "" or source.strip() == "":
        return _cors(bad_request('{"error":"name and source are required"}'))
    if not isdir(source):
        return _cors(bad_request('{"error":"source is not a directory"}'))
    var id = vaults.add_vault(name, source)
    return _cors(ok_json('{"ok":true,"id":' + json_escape(id) + "}"))


def handle_vaults_remove(req: Request) raises -> Response:
    """POST /api/vaults/remove {id} → drop a vault from the registry (the data dir is
    left on disk). The "main" vault can't be removed; removing the active vault falls
    back to "main"."""
    if _is_demo():
        return _cors(unauthorized('{"error":"vaults are fixed in the demo"}'))
    var id: String
    try:
        id = String(loads(req.text())["id"].string_value())
    except:
        return _cors(bad_request('{"error":"expected {id}"}'))
    if not vaults.remove_vault(id):
        return _cors(
            bad_request(
                '{"error":"cannot remove (unknown, or the main vault)"}'
            )
        )
    return _cors(ok_json('{"ok":true}'))


def handle_vaults_add_demo() raises -> Response:
    """POST /api/vaults/add-demo → register the hosted sample vault as an isolated
    "demo" vault and make it active (idempotent — always the same "demo" id). The
    demo vault has its OWN empty data dir, so on restart it opens on the first-run
    onboarding; "try with sample data" then fetches + indexes the sample into the
    demo vault's isolated index, never touching the real vault. Response carries the
    id + pendingRestart so the UI prompts a restart."""
    if _is_demo():
        return _cors(unauthorized('{"error":"vaults are fixed in the demo"}'))
    var id = vaults.ensure_demo_vault()
    _ = vaults.set_active(id)
    # Restart into the demo vault so its (empty) first-run onboarding comes up.
    var restarting = id != vaults.running_vault_id()
    if restarting:
        _restart_app_server_soon()
    return _cors(
        ok_json(
            '{"ok":true,"id":'
            + json_escape(id)
            + ',"restarting":'
            + ("true" if restarting else "false")
            + "}"
        )
    )
