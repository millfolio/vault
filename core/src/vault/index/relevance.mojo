"""Relevance — pure scoring helpers for UI vault search.

The embedding server returns L2-NORMALIZED (unit) vectors, so LanceDB's default
squared-L2 distance `d` between a query and a stored chunk maps cleanly to cosine
similarity: |a-b|² = |a|² + |b|² - 2·a·b = 2(1 - cos), hence cos = 1 - d/2.

`search()` is a pure k-NN — it ALWAYS returns the k nearest chunks, even when
nothing is actually relevant (a term absent from the vault). The UI search path
uses these helpers to convert the distance to an interpretable similarity and drop
hits below a floor, so an absent term returns no matches instead of junk.

Dependency-free on purpose, so it unit-tests with just `-I core/src` (mirrors
vault.index.sha256). Covered by test/index/relevance_test.mojo.
"""


def cosine_from_l2sq(d: Float64) -> Float64:
    """Cosine similarity for a hit at squared-L2 distance `d` between UNIT vectors:
    `cos = 1 - d/2`. d=0 → 1.0 (identical), d=2 → 0.0 (orthogonal), d=4 → -1.0
    (opposite). Higher is better."""
    return 1.0 - d / 2.0


def passes_min_sim(d: Float64, min_sim: Float64) -> Bool:
    """Whether a hit at squared-L2 distance `d` clears the cosine floor `min_sim`
    (inclusive). The UI search path keeps a hit iff this is True."""
    return cosine_from_l2sq(d) >= min_sim
