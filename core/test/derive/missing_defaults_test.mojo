"""Missing_defaults_test — the upgrade path that offers newly-added built-in
default tags.

Built-in default tags (`transfers`, `rewards`, …) only auto-refresh into
`categories.txt` while the file is UNTOUCHED. Once the user edits it, the file is
authoritative and a default added in a LATER version never appears — so their
ACH/Daily-Cash rows go untagged. `missing_default_tags_json` surfaces the absent
defaults; `add_default_tags` APPENDS the opted-in ones without disturbing the
user's existing rules. This drives both against a hermetic `MILLFOLIO_DATA_DIR`.
"""

from std.os import getenv, makedirs
from std.os.path import exists
from vault.derive.store import missing_default_tags_json, add_default_tags
from vault.derive.tags import categories_path, effective_tags


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _has(xs: List[String], s: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == s:
            return True
    return False


def main() raises:
    var dd = String(getenv("MILLFOLIO_DATA_DIR", "").strip())
    expect(dd != "", "MILLFOLIO_DATA_DIR must be set by the test task")
    makedirs(dd, exist_ok=True)

    # An EDITED (authoritative) categories file: it has rules but NO managed
    # checksum, so the loader treats it as the user's own and never auto-refreshes
    # the new defaults into it. It defines `groceries` + a custom tag, but is
    # missing the newer `transfers`/`rewards` defaults.
    with open(categories_path(), "w") as f:
        f.write(
            String(
                "# my rules\n"
                "groceries = costco, safeway\n"
                "side hustle = etsy, gumroad\n"
            )
        )

    # 1) The upgrade nudge lists the absent defaults (transfers, rewards) but NOT
    #    a default the user already has (groceries) nor their custom tag.
    var missing = missing_default_tags_json()
    expect(missing.find('"name":"transfers"') != -1, "transfers offered")
    expect(missing.find('"name":"rewards"') != -1, "rewards offered")
    expect(
        missing.find('"name":"groceries"') == -1, "present default not offered"
    )
    expect(missing.find("side hustle") == -1, "user's own tag not offered")
    # descriptions ride along so the UI can explain each.
    expect(
        missing.find('"description":"') != -1,
        "each offered default carries a description",
    )

    # 2) Opt in to transfers + rewards → both appended; a bogus name is ignored.
    var added = add_default_tags(
        [String("transfers"), String("rewards"), String("not-a-default")]
    )
    expect(added == 2, "exactly the two real missing defaults were added")

    # 3) They're now in the effective registry, and the user's edits survived.
    var eff = effective_tags()
    expect(_has(eff, "transfers"), "transfers now effective")
    expect(_has(eff, "rewards"), "rewards now effective")
    expect(_has(eff, "groceries"), "user's groceries preserved")
    expect(_has(eff, "side hustle"), "user's custom tag preserved")

    # 4) The nudge no longer offers what was added (idempotent), but still offers
    #    a default the user never took (phone).
    var missing2 = missing_default_tags_json()
    expect(
        missing2.find('"name":"transfers"') == -1, "transfers no longer offered"
    )
    expect(missing2.find('"name":"rewards"') == -1, "rewards no longer offered")
    expect(
        missing2.find('"name":"phone"') != -1, "untaken default still offered"
    )

    # 5) Adding again is a no-op (nothing missing among the requested names).
    expect(
        add_default_tags([String("transfers")]) == 0,
        "re-adding an already-present default adds nothing",
    )

    print("ok: all missing-defaults tests passed")
