"""Seed — arm the EgressGuard from the REAL vault (canary + fingerprints).

This is the piece that turns the guard from a checked-but-empty chokepoint into
a live tripwire. Two seeds, per the README threat model:

CANARY — a token that exists ONLY in the real private data, never in anything
synthetic. Implemented as a dotfile INSIDE the vault dir (`.enclave_canary`,
content `MILLFOLIO-CANARY-<hex>`): the trusted collectors skip leading-`.`
names (see `_collect_files` in vault/core manifest.mojo), so the canary never
reaches the manifest, the index, or an answer — but it sits inside @DATA_DIR@
where careless generated code doing a raw directory read WILL pick it up. If
the token ever shows up on the outbound path, the synthetic/real separation
broke upstream: hard fail. Minted once per vault and persisted, so it stays
stable across runs.

FINGERPRINTS — real-data spans that must never leave: the configured API key
(the one secret we hold), the vault's real path (the known past leak class —
the `vault:` line strip in harness.vault_manifest), and PII-shaped values
sampled from the first rows of the vault's CSVs (`looks_pii` — identifiers
only, NEVER merchant names/amounts/dates, which users legitimately type into
questions). Sampled values live only in process memory and feed only substring
checks that PREVENT sends — never logged, persisted, or sent.

Best-effort by design: a seeding failure (unreadable dir, no CSVs) degrades to
a less-armed guard, never to a blocked ask. The guard itself still fails closed
on whatever it WAS armed with. Bounded (file count, file size, row count)
because wiring runs per-request.
"""

from std.ffi import external_call
from std.os import listdir, makedirs
from std.os.path import isfile, isdir, getsize
from std.time import perf_counter_ns

from security.pii import looks_pii

comptime CANARY_PREFIX = "MILLFOLIO-CANARY-"
comptime CANARY_FILENAME = ".enclave_canary"

comptime _MAX_CSV_FILES = 16  # bounded per-request cost
comptime _MAX_CSV_BYTES = 262144  # skip huge CSVs; sampling is best-effort
comptime _SAMPLE_DATA_ROWS = 4  # rows AFTER the header row
comptime _MAX_FINGERPRINTS = 64
comptime _MAX_WALK_DEPTH = 6

comptime _HEX = "0123456789abcdef"


def _fnv1a_hex(s: String) -> String:
    """FNV-1a 64-bit as 16 hex chars — same construction as codegen_cache's
    stable_hash_hex, duplicated so `security/` stays a leaf package (ACYCLIC
    note in __init__.mojo)."""
    var h: UInt64 = 0xCBF29CE484222325
    var prime: UInt64 = 0x100000001B3
    var b = s.as_bytes()
    for i in range(len(b)):
        h = (h ^ UInt64(Int(b[i]))) * prime
    var out = String("")
    var shift = 60
    while shift >= 0:
        var nib = Int((h >> UInt64(shift)) & UInt64(0xF))
        out += String(_HEX[byte=nib])
        shift -= 4
    return out^


def _fresh_canary_token(vault_dir: String) -> String:
    """A per-vault token. Not a cryptographic secret — the v1 threat model is
    accident-catching, so unique-per-vault (time + pid + path) is enough."""
    var pid = Int(external_call["getpid", Int32]())
    var seed = vault_dir + ":" + String(perf_counter_ns()) + ":" + String(pid)
    return String(CANARY_PREFIX) + _fnv1a_hex(seed)


def ensure_canary(vault_dir: String) -> String:
    """The vault's canary token, minted + persisted on first use, stable
    thereafter. Returns "" when the vault dir is unusable (the guard just runs
    canary-less — best-effort, see module docstring)."""
    if vault_dir.byte_length() == 0:
        return String("")
    var path = vault_dir + "/" + String(CANARY_FILENAME)
    try:
        if isfile(path):
            var tok: String
            with open(path, "r") as f:
                tok = String(f.read().strip())
            if tok.startswith(String(CANARY_PREFIX)):
                return tok^
            # Unrecognized content — fall through and re-mint over it.
        makedirs(vault_dir, exist_ok=True)
        var fresh = _fresh_canary_token(vault_dir)
        with open(path, "w") as f:
            f.write(fresh + "\n")
        return fresh^
    except:
        return String("")


def _collect_csvs(dir: String, mut out: List[String], depth: Int) raises:
    """Recursively collect CSV paths — same dotfile-skipping rule as the
    manifest walker (which also keeps this walker from ever seeing the canary
    file), bounded in depth and count."""
    if depth > _MAX_WALK_DEPTH or len(out) >= _MAX_CSV_FILES:
        return
    var raw = listdir(dir)
    for i in range(len(raw)):
        if len(out) >= _MAX_CSV_FILES:
            return
        var name = String(raw[i])
        if name.startswith("."):
            continue
        var p = dir + "/" + name
        if isdir(p):
            _collect_csvs(p, out, depth + 1)
        elif isfile(p):
            if name.endswith(".csv") or name.endswith(".CSV"):
                out.append(p.copy())


def _clean_cell(cell: String) -> String:
    """A CSV cell, whitespace-trimmed and unquoted."""
    var v = String(cell.strip())
    if v.byte_length() >= 2 and v.startswith('"') and v.endswith('"'):
        v = String(String(v.removeprefix('"')).removesuffix('"'))
        v = String(v.strip())
    return v^


def _already_has(fps: List[String], v: String) -> Bool:
    for f in fps:
        if f == v:
            return True
    return False


def vault_fingerprints(vault_dir: String, secret: String) -> List[String]:
    """The fingerprint list to arm the guard with: the configured secret, the
    real vault path, and PII-shaped cell values from the first
    `_SAMPLE_DATA_ROWS` rows of up to `_MAX_CSV_FILES` CSVs."""
    var out = List[String]()
    if secret.byte_length() >= 8:
        out.append(secret.copy())
    if vault_dir.byte_length() >= 8:
        out.append(vault_dir.copy())
    var csvs = List[String]()
    try:
        _collect_csvs(vault_dir, csvs, 0)
    except:
        return out^  # unreadable dir — stay best-effort
    for i in range(len(csvs)):
        if len(out) >= _MAX_FINGERPRINTS:
            break
        try:
            if getsize(csvs[i]) > _MAX_CSV_BYTES:
                continue
            var text: String
            with open(csvs[i], "r") as f:
                text = f.read()
            var lines = text.split("\n")
            for r in range(
                1, len(lines)
            ):  # 0 is the header — names, not values
                if r > _SAMPLE_DATA_ROWS or len(out) >= _MAX_FINGERPRINTS:
                    break
                var cells = String(lines[r]).split(",")
                for c in range(len(cells)):
                    if len(out) >= _MAX_FINGERPRINTS:
                        break
                    var v = _clean_cell(String(cells[c]))
                    if looks_pii(v) and not _already_has(out, v):
                        out.append(v^)
        except:
            continue  # one unreadable CSV shouldn't cost the rest
    return out^
