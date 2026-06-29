"""Relevance_test — the UI search distance→cosine mapping + the relevance floor.

Builds + runs as a plain Mojo program with only `-I core/src` (no FFI/network):
`pixi run test-relevance`. Guards the fix that stopped vault search returning the
k nearest chunks for a term that's absent from the vault — `cos = 1 - d/2` over
L2-normalized embeddings, then drop hits below the cosine floor.
"""

from vault.index.relevance import cosine_from_l2sq, passes_min_sim


def _close(a: Float64, b: Float64) -> Bool:
    var d = a - b
    return d < 1e-9 and d > -1e-9


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def main() raises:
    # ── distance → cosine (unit vectors: |a-b|² = 2(1-cos)) ──────────────────────
    expect(_close(cosine_from_l2sq(0.0), 1.0), "d=0 → cos 1.0 (identical)")
    expect(_close(cosine_from_l2sq(1.0), 0.5), "d=1 → cos 0.5")
    expect(_close(cosine_from_l2sq(2.0), 0.0), "d=2 → cos 0.0 (orthogonal)")
    expect(_close(cosine_from_l2sq(4.0), -1.0), "d=4 → cos -1.0 (opposite)")

    # ── the relevance floor (default 0.4) ───────────────────────────────────────
    expect(passes_min_sim(0.0, 0.4), "identical (cos 1.0) clears 0.4")
    expect(passes_min_sim(1.0, 0.4), "cos 0.5 clears 0.4")
    expect(not passes_min_sim(1.3, 0.4), "cos 0.35 fails 0.4 (the absent-term case)")
    expect(not passes_min_sim(2.0, 0.4), "orthogonal (cos 0.0) fails 0.4")

    # ── the floor is a real parameter (lower it → the same hit clears) ───────────
    expect(passes_min_sim(1.3, 0.3), "cos 0.35 clears a lower floor of 0.3")
    expect(not passes_min_sim(1.0, 0.6), "cos 0.5 fails a higher floor of 0.6")

    print("ok: all relevance tests passed")
