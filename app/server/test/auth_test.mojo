"""auth_test — unit tests for the secrets/tokens + in-app API-key store (auth.mojo).

Builds + runs as a plain Mojo program: `pixi run test-auth` (which points
MILLFOLIO_DATA_DIR at a throwaway temp dir so all file I/O is hermetic, and rm's
it after). Covers the constant-time compare (all three branches), the hex-nibble
+ random-token primitives, the reveal-secret roundtrip (mint/validate accepts,
tamper/empty rejects), the demo-token mint→validate roundtrip, and the 0600
API-key file store (write/read/clear + persisted-key injection into Config).

Deliberately skips `_verify_turnstile` (network to Cloudflare siteverify) and the
trivial `_turnstile_*` env getters.
"""

from std.os import setenv, makedirs, remove
from std.os.path import exists

from settings import Config

from auth import (
    _const_time_eq,
    _hex_nibble,
    _new_token,
    _ensure_reveal_secret,
    _mint_reveal_token,
    _reveal_token_path,
    _mint_demo_token,
    _demo_token_valid,
    _write_apikey_file,
    _read_apikey_file,
    _clear_apikey_file,
    _apply_persisted_apikey,
    _apikey_path,
)


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def expect_eq(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + "\n  got:  " + got + "\n  want: " + want)


def _is_hex(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        var digit = c >= 48 and c <= 57
        var lower = c >= 97 and c <= 102  # a-f
        if not (digit or lower):
            return False
    return len(b) > 0


def main() raises:
    # Hermetic data dir — all secrets/tokens/API-key files land here.
    var datadir = String("/tmp/millfolio-auth-test")
    _ = setenv("MILLFOLIO_DATA_DIR", datadir, True)
    if not exists(datadir):
        makedirs(datadir)

    # ── _const_time_eq: all three branches ───────────────────────────────────────
    expect(_const_time_eq("abc123", "abc123"), "equal strings → True")
    expect(
        not _const_time_eq("abc123", "abc124"),
        "same length, one byte differs → False",
    )
    expect(not _const_time_eq("abc", "abcd"), "different lengths → False")
    expect(_const_time_eq("", ""), "empty == empty → True")

    # ── _hex_nibble: 0-15 → '0'..'9','a'..'f' ────────────────────────────────────
    expect_eq(_hex_nibble(0), "0", "nibble 0")
    expect_eq(_hex_nibble(9), "9", "nibble 9")
    expect_eq(_hex_nibble(10), "a", "nibble 10 → a")
    expect_eq(_hex_nibble(15), "f", "nibble 15 → f")

    # ── _new_token: 32 hex chars, and fresh each call ────────────────────────────
    var t1 = _new_token()
    var t2 = _new_token()
    expect(t1.byte_length() == 32, "token is 32 hex chars (128-bit)")
    expect(_is_hex(t1), "token is all lowercase hex")
    expect(t1 != t2, "two mints differ (random)")

    # ── reveal secret: idempotent + validates via const-time compare ─────────────
    # A fresh temp dir has no secret file yet; ensure creates it.
    var sp = datadir + "/.reveal-secret"
    if exists(sp):
        remove(sp)
    var secret = _ensure_reveal_secret()
    expect(secret != "", "reveal secret created (non-empty)")
    expect(_is_hex(secret), "reveal secret is hex")
    var secret2 = _ensure_reveal_secret()
    expect_eq(
        secret2, secret, "reveal secret idempotent (same value on re-read)"
    )
    # The local-unlock endpoint accepts iff the posted secret matches (const-time).
    expect(_const_time_eq(secret, secret2), "matching secret accepted")
    expect(not _const_time_eq(secret, secret + "0"), "tampered secret rejected")
    expect(not _const_time_eq(secret, ""), "empty secret rejected")

    # ── _mint_reveal_token: writes a fresh 32-hex token with a future TTL ────────
    var rtok = _mint_reveal_token()
    expect(rtok.byte_length() == 32 and _is_hex(rtok), "reveal token is 32-hex")
    var stored_rtok: String
    with open(_reveal_token_path(), "r") as f:
        stored_rtok = f.read()
    expect(stored_rtok.find(rtok) != -1, "reveal token persisted to file")

    # ── demo tokens: mint → validate accepts, garbage/empty reject ───────────────
    var dtok = _mint_demo_token()
    expect(dtok.byte_length() == 32 and _is_hex(dtok), "demo token is 32-hex")
    expect(_demo_token_valid(dtok), "freshly minted demo token is valid")
    expect(not _demo_token_valid("deadbeef"), "unknown demo token rejected")
    expect(not _demo_token_valid(""), "empty demo token rejected")
    # A second mint coexists; both remain valid (concurrent visitors).
    var dtok2 = _mint_demo_token()
    expect(_demo_token_valid(dtok2), "second demo token valid")
    expect(
        _demo_token_valid(dtok), "first demo token still valid after 2nd mint"
    )

    # ── API-key file store: write → read → clear roundtrip ───────────────────────
    _clear_apikey_file()  # start clean
    expect_eq(_read_apikey_file(), "", "no file → empty key")
    _write_apikey_file("  sk-ant-persisted-key-1234  ")
    expect_eq(
        _read_apikey_file(),
        "sk-ant-persisted-key-1234",
        "write→read roundtrip (trimmed)",
    )
    expect(exists(_apikey_path()), "apikey file exists after write")
    _clear_apikey_file()
    expect_eq(_read_apikey_file(), "", "clear → empty again")
    expect(not exists(_apikey_path()), "apikey file removed after clear")

    # ── _apply_persisted_apikey: injects the stored key only when cfg has none ────
    _write_apikey_file("sk-ant-fallback-key-5678")
    var cfg = Config(
        String("http://127.0.0.1:8000/v1"),
        String("local"),
        String("https://api.anthropic.com/v1"),
        String("claude-sonnet-5"),
        0,  # remote_token_budget zeroed (keyless/local-only)
        String(""),  # no api_key from env
        False,
        False,
        datadir.copy(),
    )
    _apply_persisted_apikey(cfg)
    expect_eq(cfg.api_key, "sk-ant-fallback-key-5678", "persisted key injected")
    expect(
        cfg.remote_token_budget == -1,
        "remote budget re-enabled when key injected",
    )

    # When cfg already has a key (env-provided), the persisted file is ignored.
    var cfg2 = Config(
        String("http://127.0.0.1:8000/v1"),
        String("local"),
        String("https://api.anthropic.com/v1"),
        String("claude-sonnet-5"),
        -1,
        String("sk-ant-env-provided-9999"),
        False,
        False,
        datadir.copy(),
    )
    _apply_persisted_apikey(cfg2)
    expect_eq(
        cfg2.api_key,
        "sk-ant-env-provided-9999",
        "env-provided key left untouched",
    )
    _clear_apikey_file()

    print("auth_test: OK")
