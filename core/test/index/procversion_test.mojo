"""Procversion_test — the index PROCESSING-VERSION mechanism.

`build_index` skips files whose name+content-hash are unchanged (no re-extract,
no re-embed). So when the extraction/parse/chunk LOGIC itself changes (e.g. the
`parse_location` that fills `.merchant`/`.state`/`.country`), existing indexes
would keep the OLD fields forever because the file bytes never changed. The fix:
a stored processing version (a tiny marker file) that, on a mismatch with the
current `INDEX_PROCESSING_VERSION`, auto-forces a full rebuild.

A full end-to-end `build_index` needs a live embeddings endpoint (unavailable in
CI), so this pins the read / compare / write LOGIC at the unit level: the marker
read+write helpers and the `index_effective_force` decision that gates the
rebuild-from-scratch path. Uses a pinned `MILLFOLIO_DATA_DIR` (set by the pixi
task) so no real vault is touched. What still needs a live embed server to
confirm: that a version-mismatch actually re-populates the location fields
end-to-end (the decision tested here is what triggers that rebuild).
"""

from std.os import getenv, makedirs
from std.os.path import exists
from vault.index.index import (
    INDEX_PROCESSING_VERSION,
    index_effective_force,
    _read_procversion,
    _write_procversion,
    _procversion_path,
)


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _clear_marker() raises:
    from std.os import remove

    if exists(_procversion_path()):
        remove(_procversion_path())


def main() raises:
    # A pinned data dir keeps the test hermetic (the task sets MILLFOLIO_DATA_DIR).
    var dd = String(getenv("MILLFOLIO_DATA_DIR", "").strip())
    expect(dd != "", "MILLFOLIO_DATA_DIR must be set by the test task")
    makedirs(dd, exist_ok=True)

    # The current version must be a real (>= 1) integer so a MISSING marker (0)
    # reads as strictly older and forces the one-time rebuild.
    expect(
        INDEX_PROCESSING_VERSION >= 1,
        "INDEX_PROCESSING_VERSION is >= 1 (got "
        + String(INDEX_PROCESSING_VERSION)
        + ")",
    )

    # 1) A fresh store has no marker → reads as 0, and the decision forces a rebuild
    #    (this is the pre-mechanism / clean-machine case).
    _clear_marker()
    expect(
        not exists(_procversion_path()),
        "no marker exists before the first build",
    )
    expect(_read_procversion() == 0, "a missing marker reads as version 0")
    expect(
        index_effective_force(0, False) == True,
        "a version-0 (missing) marker forces a rebuild even without --force",
    )

    # 2) A fully successful build stamps the CURRENT version, which then reads back.
    _write_procversion()
    expect(
        exists(_procversion_path()),
        "the marker exists after _write_procversion",
    )
    expect(
        _read_procversion() == INDEX_PROCESSING_VERSION,
        "the marker round-trips the current version (got "
        + String(_read_procversion())
        + ")",
    )

    # 3) Same version + no --force → NO forced rebuild (the incremental skip path is
    #    preserved: unchanged files are still skipped, nothing is re-embedded).
    expect(
        index_effective_force(INDEX_PROCESSING_VERSION, False) == False,
        "matching version + no force does NOT force a rebuild",
    )

    # 4) A stored version OLDER than current (simulating an index built before a
    #    pipeline change) forces a full rebuild so the new fields get populated.
    var older = INDEX_PROCESSING_VERSION - 1
    with open(_procversion_path(), "w") as f:
        f.write(String(older))
    expect(
        _read_procversion() == older,
        "an arbitrary stored version round-trips (got "
        + String(_read_procversion())
        + ")",
    )
    expect(
        index_effective_force(_read_procversion(), False) == True,
        "a stored version below the current one forces a rebuild",
    )

    # 5) Explicit --force always forces, regardless of a matching version.
    expect(
        index_effective_force(INDEX_PROCESSING_VERSION, True) == True,
        "explicit --force forces a rebuild even when the version matches",
    )

    # Leave the marker at the current version (as a real successful build would).
    _write_procversion()
    expect(
        _read_procversion() == INDEX_PROCESSING_VERSION,
        "marker left at the current version",
    )

    print("ok: all procversion tests passed")
