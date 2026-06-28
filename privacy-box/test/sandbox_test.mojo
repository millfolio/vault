"""Sandbox-test — prove the VAULT run profile grants read to the dir the index
was actually built from. `pixi run test-sandbox`.

Regression guard for the vault-dir mismatch fix: the vault readers (pdf_text /
csv_rows / md_text / docx_text) open files by their REAL path under the indexed
folder, which can differ from the served vault dir. The run sandbox must grant
read there (`@SOURCE_DIR@`), or content questions fail with "Operation not
permitted". Critically, when there's no index the grant must FALL BACK to the
served vault dir — never an empty string or "/", which would defeat read-scoping.
"""

from std.os import makedirs
from sandbox import (
    _index_source_dir,
    Sandbox,
    SandboxPolicy,
    _canonical,
    _read,
    _write,
)

comptime _TMPL = "privacy-box/sandbox/privacy_box.sb.template"


def _grants(profile: String, path: String) -> Bool:
    return profile.find('(subpath "' + path + '")') != -1


def main() raises:
    var all_ok = True
    var base = String("/tmp/pb_sandbox_test")
    var idx = base + "/index"  # the LanceDB index dir (~/.config/millfolio)
    var data = base + "/served"  # the served vault dir (@DATA_DIR@)
    var src = base + "/indexed"  # the dir the index was built from
    var scratch = base + "/scratch"
    makedirs(idx, exist_ok=True)
    makedirs(data, exist_ok=True)
    makedirs(src, exist_ok=True)
    makedirs(scratch, exist_ok=True)

    # ── _index_source_dir parses manifest.tsv's #meta source_dir ──────────────
    _write(
        idx + "/manifest.tsv",
        "#meta\t5\t2\t" + src + "\nfile_0\tstmt.pdf\tpdf\t100\tabc\t0\t1\n",
    )
    var got = _index_source_dir(idx)
    var parse_ok = got == src
    print(
        "["
        + ("PASS" if parse_ok else "FAIL")
        + "] _index_source_dir parses source_dir (got '"
        + got
        + "')"
    )
    all_ok = all_ok and parse_ok

    var none_ok = _index_source_dir(base + "/does-not-exist") == ""
    print("[" + ("PASS" if none_ok else "FAIL") + "] missing manifest -> empty")
    all_ok = all_ok and none_ok

    # ── the rendered vault profile grants read of the canonical source_dir ────
    var scratch_c = _canonical(scratch)
    var pol = SandboxPolicy(data, scratch, idx, String("loopback"))
    var sb = Sandbox(pol^, String(_TMPL))
    var prof = _read(sb._render_profile(scratch_c))
    var src_c = _canonical(src)
    var grants_src = _grants(prof, src_c)
    print(
        "["
        + ("PASS" if grants_src else "FAIL")
        + "] vault profile grants source_dir read"
    )
    all_ok = all_ok and grants_src

    var no_placeholder = prof.find("@SOURCE_DIR@") == -1
    print(
        "["
        + ("PASS" if no_placeholder else "FAIL")
        + "] @SOURCE_DIR@ fully substituted"
    )
    all_ok = all_ok and no_placeholder

    # ── no index -> @SOURCE_DIR@ falls back to the served vault dir (NOT empty) ─
    var idx2 = base + "/emptyidx"
    makedirs(idx2, exist_ok=True)
    var pol2 = SandboxPolicy(data, scratch, idx2, String("loopback"))
    var sb2 = Sandbox(pol2^, String(_TMPL))
    var prof2 = _read(sb2._render_profile(scratch_c))
    var data_c = _canonical(data)
    var fallback_ok = (prof2.find("@SOURCE_DIR@") == -1) and _grants(
        prof2, data_c
    )
    print(
        "["
        + ("PASS" if fallback_ok else "FAIL")
        + "] no index -> source grant falls back to vault dir"
    )
    all_ok = all_ok and fallback_ok

    # Guard against the catastrophic substitution: a bare-root or empty subpath.
    var no_root = (
        (prof.find('(subpath "")') == -1)
        and (prof.find('(subpath "/")') == -1)
        and (prof2.find('(subpath "")') == -1)
        and (prof2.find('(subpath "/")') == -1)
    )
    print("[" + ("PASS" if no_root else "FAIL") + "] never grants '' or '/'")
    all_ok = all_ok and no_root

    print()
    if all_ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("sandbox-test: source_dir grant failed")
