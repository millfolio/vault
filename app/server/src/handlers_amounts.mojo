"""handlers_amounts — the transaction-amount reveal gate + the transactions view.

Transaction amounts are WITHHELD from the browser until the reveal gate is
passed, so the figures never reach the client until a passphrase or a native
Touch-ID unlock mints a short-lived bearer token:
  • POST /api/auth/unlock          — passphrase → reveal token.
  • POST /api/amounts/unlock-local — native LAContext secret → the same token.
  • GET  /api/transactions         — the reconciled rows (amounts gated on the token).

Phase-1B slice 2: pure moves of the `Api.handle_*` methods (and the
`Api._reveal_authorized` helper, which only `handle_transactions` calls) to free
functions. None deref `self.st`; the `self`-qualified helper calls resolve to the
already-extracted leaf modules (`osutil`, `auth`, `httputil`, `vault.derive.store`).
`server._route` now delegates here. Behaviour is identical.
"""

from std.os.path import exists

from flare.prelude import *

from json import loads

from vault.derive.store import verify_amount_password, transactions_json

from osutil import _is_demo, _epoch_s
from auth import (
    _reveal_token_path,
    _ensure_reveal_secret,
    _mint_reveal_token,
    _const_time_eq,
)
from httputil import unauthorized, _cors, _forbidden


def handle_auth_unlock(req: Request) raises -> Response:
    """POST /api/auth/unlock {password} → if it matches the local reveal
    passphrase (`amount_password`, look it up with `mill get amount-password`),
    mint a ~15-min bearer token that unlocks `?amounts=1`. 401 on a wrong
    passphrase. The check + the secret live server-side, so this genuinely gates
    the amounts (a curl without a valid token gets `amount:null`)."""
    var candidate: String
    try:
        var j = loads(req.text())
        candidate = j["password"].string_value()
    except:
        return _cors(bad_request('{"error":"expected {password}"}'))
    if not verify_amount_password(candidate):
        return _cors(unauthorized('{"error":"wrong passphrase"}'))
    return _cors(ok_json('{"token":"' + _mint_reveal_token() + '"}'))


def handle_amounts_unlock_local(req: Request) raises -> Response:
    """POST /api/amounts/unlock-local → the NATIVE local-capability path. The
    macOS menu-bar app, after a successful `LAContext` Touch-ID / login-password
    check, reads the `.reveal-secret` file and presents it here (JSON `{secret}`
    or the `X-Millfolio-Reveal-Secret` header). On a constant-time match we mint
    the SAME reveal token the passphrase path mints — so amounts unlock identically.
    Localhost-only (rides the Tier-1 loopback guard in `_route`). DENIED in the
    demo (its amounts are already public → no gate to bridge). The passphrase
    endpoint is untouched, so a browser with no native bridge is unaffected.
    """
    if _is_demo():
        return _forbidden('{"error":"not available in demo"}')
    var presented = String(req.headers.get("x-millfolio-reveal-secret"))
    if presented == "":
        try:
            var j = loads(req.text())
            presented = j["secret"].string_value()
        except:
            presented = String("")
    var secret = _ensure_reveal_secret()
    if secret == "" or presented == "" or not _const_time_eq(presented, secret):
        return _cors(unauthorized('{"error":"bad local secret"}'))
    return _cors(ok_json('{"token":"' + _mint_reveal_token() + '"}'))


def _reveal_authorized(req: Request) raises -> Bool:
    """True iff the request carries a valid, unexpired reveal token
    (`Authorization: Bearer <token>`) matching the one minted by unlock."""
    var auth = String(req.headers.get("authorization"))
    if not auth.startswith("Bearer "):
        return False
    var tok = String(auth.removeprefix("Bearer ").strip())
    if tok == "" or not exists(_reveal_token_path()):
        return False
    var line: String
    with open(_reveal_token_path(), "r") as f:
        line = f.read()
    var parts = line.split(" ")
    if len(parts) < 2 or String(parts[0].strip()) != tok:
        return False
    return _epoch_s() < Int64(atol(String(parts[1].strip())))


def handle_transactions(req: Request) raises -> Response:
    """GET /api/transactions → {"transactions":[{file,date,year,amount,direction,
    desc,tags}]} — the exact reconciled rows, each with its derived category tags.
    The amounts are WITHHELD (`amount:null`) unless `?amounts=1` AND the request
    carries a valid Touch-ID reveal token — so the figures never reach the browser
    until the gate is passed. In-process via vault.derive.store; no engine spawn.
    """
    var inc = _is_demo() or (
        req.query_param("amounts") == "1" and _reveal_authorized(req)
    )
    return _cors(ok_json(transactions_json(inc)))
