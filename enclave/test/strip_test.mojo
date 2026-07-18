"""Strip-test — `_strip_progress` drops the RESULT-SPEC line from the captured
answer (COMPUTE_VS_RENDER.md, Phase 1). The generated program emits its serialized
`v:1` spec on a `RESULT_SENTINEL` line alongside progress/stat/local lines; the
final reply text must contain ONLY the real answer, with every internal sentinel
line — RESULT included — removed. `pixi run test-strip`.
"""

from orchestrator import (
    _strip_progress,
    PROGRESS_SENTINEL,
    STAT_SENTINEL,
    LOCAL_SENTINEL,
    RESULT_SENTINEL,
)


def _expect(name: String, cond: Bool, prev: Bool) -> Bool:
    print("[" + ("PASS" if cond else "FAIL") + "]", name)
    return prev and cond


def main() raises:
    var ok = True

    # A captured stdout with the real answer interleaved with every sentinel line,
    # including a full RESULT spec line.
    var spec = (
        '{"v":1,"text":"You spent'
        ' $10.00.","data":[{"kind":"kpi","label":"Total",'
        '"value":{"type":"money","raw":10.0,"text":"$10.00"}}]}'
    )
    var captured = (
        String(PROGRESS_SENTINEL)
        + "reading 1/2\n"
        + "You spent $10.00.\n"
        + String(STAT_SENTINEL)
        + "transactions\t1.2\n"
        + String(RESULT_SENTINEL)
        + spec
        + "\n"
        + String(LOCAL_SENTINEL)
        + "sent\x1f=>\x1fgot\n"
        + "See the table below."
    )

    var out = _strip_progress(captured)

    # The RESULT line — and every other sentinel line — is gone.
    ok = _expect(
        "RESULT sentinel line removed", out.find(RESULT_SENTINEL) == -1, ok
    )
    ok = _expect(
        "serialized spec removed from text", out.find('"kind":"kpi"') == -1, ok
    )
    ok = _expect("progress line removed", out.find(PROGRESS_SENTINEL) == -1, ok)
    ok = _expect("stat line removed", out.find(STAT_SENTINEL) == -1, ok)
    ok = _expect("local line removed", out.find(LOCAL_SENTINEL) == -1, ok)

    # The real answer text survives, intact and joined.
    ok = _expect("answer line 1 kept", out.find("You spent $10.00.") != -1, ok)
    ok = _expect(
        "answer line 2 kept", out.find("See the table below.") != -1, ok
    )
    ok = _expect("no leftover sentinel bytes", out.find("\x1f") == -1, ok)

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("strip-test failed")
