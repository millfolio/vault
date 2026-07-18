"""EgressGuard — the single outbound chokepoint toward the remote model.

enclave's CONFIDENTIALITY guarantee lives here. Every payload bound for the
remote (frontier) model passes through `check()` before it reaches the network
transport (transport.mojo). Nothing leaves the machine without clearing this gate.

For the careful-SaaS threat model (PRIOR-ART.md) the guard is a cheap, automatic
accident-catcher — not an adversary-proof filter:

  1. canary tripwire   — tokens seeded ONLY into the real private data
                         (seed.ensure_canary — a dotfile inside the vault dir).
                         One on the outbound path means the synthetic/real
                         separation broke upstream: hard fail.
  2. fingerprint trip  — fingerprints of real data values (seed.vault_fingerprints
                         — the secret, the real vault path, PII-shaped CSV cells);
                         a match means real data is about to leave: hard fail.
  3. redaction         — a PII scrub (pii.redact_pii — emails + long digit runs)
                         applied to whatever survives.

Matching is NORMALIZED (case-folded, whitespace-dropped) on both sides, so
trivial reformatting can't slip a seeded value past. Base64/hex re-encoding
would — that's the adversarial-provider threat model, out of scope for v1.

Fails CLOSED: any tripwire raises, and the caller (transport) MUST abort the send.

This is the pi `pi-ai` lesson applied (PRIOR-ART.md): isolate transport in one
layer so there is exactly one place to enforce data-egress policy.
"""

from security.pii import redact_pii

# A shorter normalized needle would match almost any payload — dropping it is
# safer than a guard that blocks every send (a self-DoS, not confidentiality).
comptime _MIN_NEEDLE = 4


def _normalize(s: String) -> String:
    """Matching form: ASCII-lowercased, ALL whitespace dropped. Applied to the
    payload AND every needle, so the substring test is reformat-tolerant.
    (chr() re-encodes non-ASCII bytes, but both sides get the identical
    transform, so matching is unaffected — this string is never emitted.)"""
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 32 or c == 9 or c == 10 or c == 13:
            continue
        if c >= 65 and c <= 90:  # 'A'..'Z'
            c += 32
        out += chr(c)
    return out^


struct EgressGuard(Movable):
    var fingerprints: List[String]  # NORMALIZED real-data spans
    var canaries: List[String]  # NORMALIZED tokens seeded ONLY into real data

    def __init__(
        out self, var fingerprints: List[String], var canaries: List[String]
    ):
        """Needles are stored normalized; empty/too-short ones are dropped."""
        self.fingerprints = List[String]()
        self.canaries = List[String]()
        for f in fingerprints:
            var nf = _normalize(f)
            if nf.byte_length() >= _MIN_NEEDLE:
                self.fingerprints.append(nf^)
        for c in canaries:
            var nc = _normalize(c)
            if nc.byte_length() >= _MIN_NEEDLE:
                self.canaries.append(nc^)

    def check(self, payload: String) raises -> String:
        """Return a redaction-scrubbed payload safe to send, or raise. Fails closed.
        """
        var norm = _normalize(payload)
        for c in self.canaries:
            if norm.find(c) != -1:
                raise Error(
                    "EgressBlocked: canary token on outbound path — real data"
                    " leaked into a remote-bound payload upstream of the guard"
                )
        for f in self.fingerprints:
            if norm.find(f) != -1:
                raise Error(
                    "EgressBlocked: real-data fingerprint on outbound path"
                )
        return redact_pii(payload)
