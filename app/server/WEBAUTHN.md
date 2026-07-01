# Server-side WebAuthn (Touch-ID) enforcement for "reveal amounts"

Status: **prototype** — verification core built + unit-tested; endpoints/route
wiring documented (not yet applied to `server.mojo`, which has a concurrent
change in flight). New files only:

- `server/src/webauthn.mojo` — the verification module + storage + randomness.
- `server/test/webauthn_test.mojo` — the ES256 test-vector proof.
- `server/pixi.toml` — new `test-webauthn` task (added to `test-all`).

## 1. Feasibility verdict — ES256 verification is reachable

**Yes.** WebAuthn assertions are signed **ES256 = ECDSA over NIST P-256
(secp256r1) with SHA-256**. flare links OpenSSL 3 (`flare/tls/ffi/build.sh`
compiles `openssl_wrapper.cpp` with `-lssl -lcrypto`), and the full OpenSSL 3
`libcrypto` ships in the pixi env:

```
app/server/.pixi/envs/default/lib/libcrypto.3.dylib   (→ libcrypto.dylib)
```

`nm -gU` confirms every symbol the verify path needs is exported:

| symbol | role |
|---|---|
| `EC_KEY_new_by_curve_name` | make a P-256 key (NID 415) |
| `BN_bin2bn` | load X, Y, r, s big-endian magnitudes |
| `EC_KEY_set_public_key_affine_coordinates` | set + **validate on-curve** the pubkey |
| `ECDSA_SIG_new` / `ECDSA_SIG_set0` | build the (r,s) signature object |
| `ECDSA_do_verify` | the verification (returns 1 valid / 0 invalid / -1 err) |
| `EC_KEY_free` / `BN_free` / `ECDSA_SIG_free` | cleanup |

These are reached with pure Mojo `OwnedDLHandle` FFI (no C wrapper, no flare
edit) — same mechanism `flare/crypto/hmac.mojo` uses for `libflare_tls`, except
we dlopen `libcrypto` directly (`$CONDA_PREFIX/lib/libcrypto.dylib`, with `.so` /
`.so.3` / bare-soname fallbacks in `_find_libcrypto`).

Two implementation notes discovered while building this:
- `d2i_ECDSA_SIG` (the DER-parse-in-one-call helper) needs a `const uint8_t**`
  out-param; the pointer-to-pointer round-trips poorly through Mojo FFI and
  returned NULL. **We parse the DER `SEQUENCE{INTEGER r, INTEGER s}` in Mojo
  (`_parse_der_ecdsa_sig`) and build the sig with `ECDSA_SIG_set0`** — cleaner
  and fully controlled.
- Mojo's ASAP destruction reclaims the `digest`/`rs` byte buffers as soon as
  their pointers are read, *before* the C code dereferences them. The verify
  helper anchors them with `_ = len(digest)` after the call (the documented
  flare idiom).

SHA-256 is pure Mojo (`sha256_raw`, mirrors `vault/core .../index/sha256.mojo`
but returns raw bytes) — only the final ECDSA step touches `libcrypto`.

**Fallback (not needed):** had `libcrypto` been unreachable, the options were
(a) add an `flare_es256_verify` wrapper to `openssl_wrapper.cpp` and rebuild the
flare FFI `.so`, or (b) vendor a pure-Mojo P-256. Neither is required.

## 2. Module API (`webauthn.mojo`)

```
base64url_encode / base64url_decode        # RFC 4648 §5, no padding
bytes_to_hex / hex_to_bytes                # pubkey persistence
sha256_raw(bytes) -> 32 bytes              # pure Mojo

parse_auth_data(bytes) -> AuthData         # rpIdHash[32] flags[1] signCount[4]
    AuthData.user_present() / .user_verified()  # flags & 0x01 / & 0x04
check_client_data(cdj, challenge_b64u, origin)  # type/challenge/origin, raises
pubkey_from_spki(der) -> [X, Y]            # P-256 SPKI (getPublicKey()) → coords

verify_es256(X, Y, message, der_sig) -> Bool     # the ECDSA-verify FFI
verify_assertion(authData_b64u, clientDataJSON_b64u, signature_b64u,
                 X, Y, challenge_b64u, origin, rp_id,
                 stored_sign_count, require_uv=True) -> UInt32
    # full check; returns new signCount to persist, raises on any failure

random_bytes(n) / new_challenge_b64u() / new_token()   # /dev/urandom CSPRNG
Enrollment(credential_id, pub_x, pub_y, sign_count)
save_enrollment(dir, e) / load_enrollment(dir) -> Enrollment   # webauthn.json
```

`verify_assertion` enforces, in order: **ceremony type** (`webauthn.get`),
**challenge** match (anti-replay), **origin** match, **rpIdHash ==
SHA-256(rpId)**, **UP** flag, **UV** flag (the Touch-ID proof), **signCount**
strictly increasing (anti-clone), then the **ECDSA signature** over
`authenticatorData ‖ SHA-256(clientDataJSON)`.

## 3. Endpoint / flow design

rpId = `localhost`, origin = `http://localhost:10000` (the served app).

### `POST /api/auth/challenge` → `{ "challenge": "<b64url>" }`
`new_challenge_b64u()`; store it server-side single-use with a short TTL (see
challenge store below). The browser passes it to
`navigator.credentials.get({ publicKey: { challenge, ... } })`.

### `POST /api/auth/enroll  { credentialId, publicKey }` → `{ "ok": true }`
One-time registration. The browser runs `navigator.credentials.create(...)`
then sends `credentialId` (b64url) and `publicKey` = base64url of
`response.getPublicKey()` (**SPKI DER** — avoids CBOR/COSE parsing of the
attestationObject). Server: `pubkey_from_spki(spki) -> [X,Y]`, then
`save_enrollment(dir, Enrollment(credId, X, Y, 0))`. (Clients that already hold
raw `{x,y}` may send those instead.)

### `POST /api/auth/verify { credentialId, authenticatorData, clientDataJSON, signature }` → `{ "token": "<b64url>" }`
The unlock. All four fields are base64url (as `PublicKeyCredential.response`
exposes them). Server:
1. `load_enrollment(dir)`; check `credentialId` matches.
2. pop the stored challenge (single-use; reject if absent/expired).
3. `verify_assertion(authenticatorData, clientDataJSON, signature, X, Y,
   challenge, "http://localhost:10000", "localhost", stored_sign_count)`.
4. on success: persist the returned new signCount
   (`save_enrollment` with updated count), mint `new_token()`, store it in the
   token store with a ~5-min expiry, return `{token}`.
5. on any raise → `401` with the reason.

### `GET /api/transactions?amounts=1` — now gated
Amounts are released only with a valid unexpired bearer token
(`Authorization: Bearer <token>`, or a `mf_reveal` cookie). Without it,
`?amounts=1` is ignored and amounts stay withheld (`amount:null`) — exactly
today's default-safe behavior.

### Two tiny in-memory stores (server struct fields or a small file)
- **challenge store:** `{challenge_b64u -> issued_epoch}`; single-use (delete on
  verify), TTL ~2 min. Use `_epoch_s()` for expiry.
- **token store:** `{token -> expiry_epoch}`; TTL ~5 min; delete on expiry.

Both can be plain `Dict[String, Int64]` guarded by the server's existing
concurrency model, or a JSONL file in the data dir if cross-process is needed.

## 4. Exact `server.mojo` integration points

All line numbers against the current `app/server/src/server.mojo`.

1. **Route table** (the `handle_request`/dispatch chain, ~L415–475). Add three
   POST routes next to the existing `if path == "/api/transactions"` (L451):
   ```mojo
   if req.method == Method.POST and path == "/api/auth/challenge":
       return _cors(self.handle_auth_challenge())
   if req.method == Method.POST and path == "/api/auth/enroll":
       return _cors(self.handle_auth_enroll(req))
   if req.method == Method.POST and path == "/api/auth/verify":
       return _cors(self.handle_auth_verify(req))
   ```

2. **`handle_transactions`** (L603–610). It already computes
   `var inc = req.query_param("amounts") == "1"`. Gate `inc` on a valid token:
   ```mojo
   var inc = req.query_param("amounts") == "1"
   if inc and not self._reveal_authorized(req):
       inc = False          # or: return _cors(unauthorized(...))
   return _cors(ok_json(transactions_json(inc)))
   ```
   `_reveal_authorized(req)` reads the `Authorization` header (Bearer token) or
   the `mf_reveal` cookie and checks it against the token store (present +
   unexpired). Request header access mirrors the existing WS-upgrade header
   reads in `serve(...)`; `query_param` already exists on `Request`.

3. **New handler methods + stores** on the server struct. Use the module:
   `from webauthn import verify_assertion, new_challenge_b64u, new_token,
   load_enrollment, save_enrollment, Enrollment, pubkey_from_spki,
   base64url_decode`. Reuse `_config_dir()` for the data dir, `loads` for the
   request JSON, `_epoch_s()` for TTLs, `ok_json`/`bad_request`/`_cors` for
   responses. Add an `unauthorized(body)` helper (401) alongside `bad_request`.

4. **Build wiring:** `webauthn.mojo` lives in `src/`, so `-I src` (already in the
   `build` task) resolves it; it needs only `json` (already `-I ../../json`) and
   the stdlib. No new `-I`. At runtime it dlopens `libcrypto` from
   `$CONDA_PREFIX/lib` — already present because the `flare-ffi` task populates
   that dir and the server runs in the pixi env.

## 5. What's left to fully wire it

- [ ] Apply the route additions + `handle_auth_*` methods + `_reveal_authorized`
      to `server.mojo` (deferred — concurrent change in flight there).
- [ ] Add the challenge + token stores (Dict fields or a data-dir file) with TTL
      pruning via `_epoch_s()`.
- [ ] Persist the updated signCount after each successful verify
      (`save_enrollment` with `verify_assertion`'s return value).
- [ ] `unauthorized()` 401 response helper.
- [ ] Web UI: replace the client-only Touch-ID screen with the real ceremony —
      `POST /api/auth/challenge` → `navigator.credentials.get` → `POST
      /api/auth/verify` → keep the token → send it on `?amounts=1`. One-time
      `POST /api/auth/enroll` via `navigator.credentials.create` +
      `getPublicKey()`.
- [ ] Decide UX for "not yet enrolled" (first-run enrollment prompt) and token
      renewal (re-prompt Touch-ID when the 5-min token lapses).
- [ ] Optional hardening: constant-time credentialId compare; rate-limit
      `/api/auth/verify`; bind the token to signCount so a stale token can't
      outlive a re-auth.

## 6. Test / proof

`pixi run test-webauthn` (in `app/server`, i.e. the pixi env). Builds
`test/webauthn_test.mojo` and runs it against a **frozen P-256 assertion vector
generated with OpenSSL and independently verified by `openssl dgst -sha256
-verify`** before freezing. It asserts:

- base64url + hex roundtrips; `SHA-256("abc")` / `SHA-256("")` known digests.
- authData parse: UP set, **UV set**, signCount 5, `rpIdHash ==
  SHA-256("localhost")` (`49960de5…`).
- clientDataJSON: good passes; wrong challenge and wrong origin rejected.
- `pubkey_from_spki` recovers the exact (X, Y).
- **`verify_es256` == True for the good signature; == False for a tampered
  signature and a tampered message; rejected for a wrong public key.**
- `verify_assertion` end-to-end returns new signCount 5; rejects non-increasing
  signCount (clone), missing UV, and wrong challenge.
- enrollment `save`/`load` roundtrip; `random_bytes(32)` length + distinct
  challenges.

Result: **`ok: all webauthn tests passed`** (deterministic across repeated runs).
