"""vaults — the multi-vault registry (switch model).

A "vault" is a (SOURCE dir, DERIVED data dir) pair. The whole stack already
resolves both from two env vars — `MILLFOLIO_VAULT` (source) and
`MILLFOLIO_DATA_DIR` (derived: index/transactions/tags/docs). So switching vaults
needs NO change to any resolver: we keep a small registry of vaults + the active
one, and at server BOOT set those two env vars to the active vault. Switching is
therefore a restart-scoped operation — pick a vault, then restart to load it
(the UI surfaces "restart to apply", like a version change).

Layout (real product only — the public demo stays a fixed single vault):
  ~/Library/Application Support/Millfolio/
    vaults.json              the registry: {"active": id, "vaults": [{id,name,source}]}
    data/                    the DEFAULT "main" vault's derived data (LEGACY path — no migration)
    data/vaults/<id>/        every OTHER vault's derived data (fully isolated)

The registry path is FIXED (not under the data dir), so it's unaffected by the
per-vault `MILLFOLIO_DATA_DIR` we set. Isolation is total: each vault has its own
index, transactions, tags, and documents — real and synthetic data never mix.
"""

from std.os import getenv, setenv, makedirs
from std.os.path import isfile, isdir

from json import loads

from osutil import _is_demo
from events import json_escape

comptime MAIN_ID = "main"
comptime DEMO_ID = "demo"


@fieldwise_init
struct Vault(Copyable, Movable):
    var id: String
    var name: String
    var source: String  # the vault's SOURCE dir (files)


@fieldwise_init
struct Registry(Copyable, Movable):
    var active: String
    var vaults: List[Vault]


def _app_dir() -> String:
    """The Millfolio application-support dir (parent of `data/`). Holds the
    registry. Fixed — independent of MILLFOLIO_DATA_DIR (which we set per vault).
    """
    return getenv("HOME", ".") + "/Library/Application Support/Millfolio"


def _base_data() -> String:
    """The DEFAULT vault's data dir — the legacy `data/` location, so the existing
    single vault keeps its index/tags/transactions with zero migration."""
    return _app_dir() + "/data"


def registry_path() -> String:
    return _app_dir() + "/vaults.json"


def vault_data_dir(id: String) -> String:
    """A vault's derived-data dir. "main" = the legacy base (back-compat); every
    other vault is isolated under `data/vaults/<id>/`."""
    if id == MAIN_ID:
        return _base_data()
    return _base_data() + "/vaults/" + id


def _default_main_source() -> String:
    """Seed the "main" vault's source from the inherited env, in vaultcfg's own
    precedence (PRIVACY_BOX_VAULT_DIR > MILLFOLIO_VAULT), else the default vault dir.
    """
    var pv = String(getenv("PRIVACY_BOX_VAULT_DIR", "").strip())
    if pv.byte_length() > 0:
        return pv
    var v = String(getenv("MILLFOLIO_VAULT", "").strip())
    if v.byte_length() > 0:
        return v
    return getenv("HOME", ".") + "/millfolio"


def load_registry() raises -> Registry:
    """Read `vaults.json` → Registry(active, vaults). Missing/unparseable → an empty
    list and "" active (the caller seeds "main")."""
    var vaults = List[Vault]()
    var active = String("")
    var path = registry_path()
    if not isfile(path):
        return Registry(active^, vaults^)
    var text: String
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        return Registry(active^, vaults^)
    try:
        var v = loads(text)
        active = String(v["active"].string_value())
        var arr = v["vaults"]
        for i in range(arr.array_count()):
            ref e = arr[i]
            vaults.append(
                Vault(
                    String(e["id"].string_value()),
                    String(e["name"].string_value()),
                    String(e["source"].string_value()),
                )
            )
    except:
        pass  # malformed → treat as empty, re-seed
    return Registry(active^, vaults^)


def _serialize(active: String, vaults: List[Vault]) -> String:
    var out = String('{"active":') + json_escape(active) + ',"vaults":['
    for i in range(len(vaults)):
        if i > 0:
            out += ","
        out += '{"id":' + json_escape(vaults[i].id)
        out += ',"name":' + json_escape(vaults[i].name)
        out += ',"source":' + json_escape(vaults[i].source) + "}"
    out += "]}"
    return out^


def save_registry(active: String, vaults: List[Vault]) raises:
    try:
        makedirs(_app_dir(), exist_ok=True)
    except:
        pass
    with open(registry_path(), "w") as f:
        f.write(_serialize(active, vaults))


def _find(vaults: List[Vault], id: String) -> Int:
    for i in range(len(vaults)):
        if vaults[i].id == id:
            return i
    return -1


def activate_selected_vault() raises:
    """BOOT hook: seed "main" on first run, then set MILLFOLIO_VAULT +
    MILLFOLIO_DATA_DIR to the active vault so every downstream resolver (unchanged)
    points at it. Call ONCE at the top of `main()`, before any thread starts (setenv
    is process-global) and before the vault dir / data dir are first resolved.
    No-op in the demo (fixed single vault)."""
    if _is_demo():
        return
    # Capture the INHERITED primary-vault source (from the launch agent) BEFORE we
    # override any env below, so "main" always tracks the folder the user configured
    # — repointing the vault in Settings rewrites the launch agent, and this keeps
    # the registry's "main" in step rather than pinning a stale path.
    var inherited_main = _default_main_source()
    var reg = load_registry()
    var active = reg.active
    var vaults = reg.vaults.copy()
    var dirty = False
    if len(vaults) == 0:
        # First run — register the existing single vault as "main".
        vaults.append(
            Vault(String(MAIN_ID), String("My Vault"), inherited_main)
        )
        active = String(MAIN_ID)
        dirty = True
    else:
        var mi = _find(vaults, MAIN_ID)
        if mi >= 0 and vaults[mi].source != inherited_main:
            vaults[mi].source = inherited_main
            dirty = True
    if dirty:
        save_registry(active, vaults)
    var idx = _find(vaults, active)
    if idx < 0:
        idx = 0  # stale active id → fall back to the first vault
    var source = vaults[idx].source
    var data = vault_data_dir(vaults[idx].id)
    try:
        makedirs(data, exist_ok=True)
    except:
        pass
    # Set ALL THREE resolver inputs to the active vault. PRIVACY_BOX_VAULT_DIR
    # outranks MILLFOLIO_VAULT in vaultcfg.vault_dir() and the launch agent bakes it,
    # so overriding only MILLFOLIO_VAULT would leave the switch ignored — set it too.
    _ = setenv("PRIVACY_BOX_VAULT_DIR", source, True)
    _ = setenv("MILLFOLIO_VAULT", source, True)
    _ = setenv("MILLFOLIO_DATA_DIR", data, True)
    # Record which vault THIS process actually booted on, so the UI can detect a
    # pending switch (registry active != running) and prompt "restart to apply".
    _ = setenv("MILLFOLIO_ACTIVE_VAULT", vaults[idx].id, True)


def running_vault_id() -> String:
    """The vault id this process booted on (set by activate_selected_vault). "main"
    if unset (demo / pre-registry)."""
    var v = String(getenv("MILLFOLIO_ACTIVE_VAULT", ""))
    if v.byte_length() == 0:
        return String(MAIN_ID)
    return v^


def registry_json() raises -> String:
    """GET /api/vaults body: the vaults + which is active + each one's data dir.
    Seeds "main" if the registry is empty (so a fresh install always shows one).
    """
    var reg = load_registry()
    var active = reg.active
    var vaults = reg.vaults.copy()
    if len(vaults) == 0:
        vaults.append(
            Vault(String(MAIN_ID), String("My Vault"), _default_main_source())
        )
        active = String(MAIN_ID)
    if _find(vaults, active) < 0 and len(vaults) > 0:
        active = vaults[0].id
    var running = running_vault_id()
    var out = String('{"active":') + json_escape(active)
    out += ',"running":' + json_escape(running)
    out += ',"pendingRestart":' + ("true" if active != running else "false")
    out += ',"vaults":['
    for i in range(len(vaults)):
        if i > 0:
            out += ","
        out += '{"id":' + json_escape(vaults[i].id)
        out += ',"name":' + json_escape(vaults[i].name)
        out += ',"source":' + json_escape(vaults[i].source)
        out += ',"active":' + ("true" if vaults[i].id == active else "false")
        out += "}"
    out += "]}"
    return out^


def set_active(id: String) raises -> Bool:
    """Mark `id` active (persisted). Returns False if the id isn't registered. The
    change takes effect on the next server start (switching is restart-scoped).
    """
    var reg = load_registry()
    var vaults = reg.vaults.copy()
    if _find(vaults, id) < 0:
        return False
    save_registry(id, vaults)
    return True


def _slugify(name: String) -> String:
    """A filesystem-safe vault id from a display name: lowercased alnum, dashes for
    runs of anything else. Empty → "vault"."""
    var out = String("")
    var b = name.as_bytes()
    var prev_dash = False
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:
            c += 32  # lowercase
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
            out += chr(c)
            prev_dash = False
        elif not prev_dash and out.byte_length() > 0:
            out += "-"
            prev_dash = True
    var s = String(out.strip("-"))
    if s.byte_length() == 0:
        return String("vault")
    return s^


def add_vault(name: String, source: String) raises -> String:
    """Register a new vault; returns its id. The id is a slug of `name`, made unique
    against existing ids. Does NOT switch to it or index it — the caller does.
    """
    var reg = load_registry()
    var active = reg.active
    var vaults = reg.vaults.copy()
    if len(vaults) == 0:
        vaults.append(
            Vault(String(MAIN_ID), String("My Vault"), _default_main_source())
        )
        active = String(MAIN_ID)
    var base = _slugify(name)
    var id = base
    var n = 2
    while _find(vaults, id) >= 0:
        id = base + "-" + String(n)
        n += 1
    vaults.append(Vault(id, name, source))
    save_registry(active, vaults)
    return id^


def ensure_demo_vault() raises -> String:
    """Idempotently register the isolated "demo" vault, returning its id. Its source
    is a placeholder under its own data dir — the demo vault is populated via the
    first-run "try with sample data" onboarding (which writes into whatever data dir
    is active), NOT by folder-indexing, so the source is only cosmetic here."""
    var reg = load_registry()
    var active = reg.active
    var vaults = reg.vaults.copy()
    if len(vaults) == 0:
        vaults.append(
            Vault(String(MAIN_ID), String("My Vault"), _default_main_source())
        )
        active = String(MAIN_ID)
    if _find(vaults, DEMO_ID) < 0:
        vaults.append(
            Vault(
                String(DEMO_ID),
                String("Demo Vault"),
                vault_data_dir(DEMO_ID) + "/sample",
            )
        )
        save_registry(active, vaults)
    return String(DEMO_ID)


def remove_vault(id: String) raises -> Bool:
    """Drop a vault from the registry (the "main" vault can't be removed). Its data
    dir is left on disk. If it was active, "main" becomes active."""
    if id == MAIN_ID:
        return False
    var reg = load_registry()
    var active = reg.active
    var vaults = reg.vaults.copy()
    var idx = _find(vaults, id)
    if idx < 0:
        return False
    var kept = List[Vault]()
    for i in range(len(vaults)):
        if i != idx:
            kept.append(vaults[i].copy())
    if active == id:
        active = String(MAIN_ID)
    save_registry(active, kept)
    return True
