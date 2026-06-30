"""Categorize — the deterministic tag matcher (cheap, pure, the common case).

A `Registry` is an ordered list of `Rule`s; each `Rule` maps a TAG (e.g.
`"phone"`) to a set of case-insensitive substring keywords (and optional
exclude keywords that veto a match). `Registry.tags_for(desc)` returns EVERY tag
whose rule matches the description — tags are multi-valued, so one transaction
can be both `travel` and `restaurant` (an airport meal).

This is the cheap+pure half of the design (see `QUERY_FLOW.md`): it runs in
microseconds with no model call and is fully deterministic, so it both answers
the common case and acts as a guardrail around the ML tail — a credit-card
``Crd Epay`` with a long account-number digit run matches NO carrier keyword, so
it can never be mislabeled `phone` (the false-positive class the on-device model
hit). The fuzzy tail (a merchant no rule names) is a separate, cached ML
attribute; this module deliberately depends only on the stdlib so it unit-tests
with just `-I core/src` (mirrors `vault.index.relevance` / `vault.index.sha256`).

The seed registry below is the built-in taxonomy; the user-editable persisted
registry (load/merge from a config file) and index-time materialisation are the
next increments — `tags_for` is written to take ANY `Registry` so it doesn't
care where the rules came from.
"""


def _lower(s: String) -> String:
    """ASCII-lowercase a copy of ``s`` (descriptions + keywords are ASCII)."""
    var out = String(capacity=s.byte_length() + 1)
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        var c = Int(p[i])
        if c >= 65 and c <= 90:
            out += chr(c + 32)
        else:
            out += chr(c)
    return out^


@fieldwise_init
struct Rule(Copyable, Movable):
    """One tag and the keywords that assign it. ``keywords`` and ``excludes``
    are matched as case-insensitive SUBSTRINGS of the description; a rule
    matches when ANY keyword is present and NO exclude is. Keep keywords
    specific enough to avoid substring collisions (e.g. ``"at&t"`` /
    ``"att*bill"``, not a bare ``"att"`` that would hit ``"mattress"``)."""

    var tag: String
    var keywords: List[String]
    var excludes: List[String]

    def matches(self, desc_lower: String) -> Bool:
        """Whether this rule applies to an already-lowercased description."""
        var hit = False
        for i in range(len(self.keywords)):
            if _lower(self.keywords[i]) in desc_lower:
                hit = True
                break
        if not hit:
            return False
        for i in range(len(self.excludes)):
            if _lower(self.excludes[i]) in desc_lower:
                return False
        return True


@fieldwise_init
struct Registry(Copyable, Movable):
    """An ordered set of tag rules. Order only affects the order of returned
    tags, not whether they match (a transaction gets every matching rule's
    tag)."""

    var rules: List[Rule]

    def tags_for(self, desc: String) -> List[String]:
        """Every tag whose rule matches ``desc`` (case-insensitive). Empty when
        nothing matches — the caller then falls back to the cached ML tag (or
        leaves it untagged). Multi-valued by design."""
        var d = _lower(desc)
        var tags = List[String]()
        for i in range(len(self.rules)):
            if self.rules[i].matches(d):
                tags.append(self.rules[i].tag.copy())
        return tags^


def _rule(var tag: String, var keywords: List[String]) -> Rule:
    """A keyword-only rule (no excludes)."""
    return Rule(tag^, keywords^, List[String]())


def default_registry() -> Registry:
    """The built-in seed taxonomy. Curated, specific keywords (bank
    descriptions are terse and upper-cased), tuned to avoid the obvious
    substring collisions. This is the starting point a user-editable registry
    will extend/override."""
    var rules = List[Rule]()
    rules.append(
        _rule(
            "phone",
            [
                "verizon",
                "at&t",
                "att*bill",
                "t-mobile",
                "tmobile",
                "sprint pcs",
                "mint mobile",
                "google fi",
                "cricket wireless",
                "us cellular",
                "boost mobile",
                "xfinity mobile",
                "metro by t-mobile",
            ],
        )
    )
    rules.append(
        _rule(
            "travel",
            [
                "air lines",
                "airline",
                "delta air",
                "united air",
                "american airlines",
                "southwest air",
                "jetblue",
                "alaska air",
                "marriott",
                "hilton",
                "hyatt",
                "airbnb",
                "expedia",
                "booking.com",
                "hertz",
                "avis",
                "amtrak",
                "hotel",
            ],
        )
    )
    rules.append(
        _rule(
            "restaurant",
            [
                "restaurant",
                "starbucks",
                "mcdonald",
                "chipotle",
                "doordash",
                "uber eats",
                "ubereats",
                "grubhub",
                "pizza",
                "cafe",
                "coffee",
                "grill",
                "taqueria",
                "sushi",
                "diner",
            ],
        )
    )
    rules.append(
        _rule(
            "groceries",
            [
                "grocery",
                "supermarket",
                "whole foods",
                "trader joe",
                "safeway",
                "kroger",
                "costco",
                "walmart",
                "aldi",
                "publix",
                "wegmans",
                "sprouts",
            ],
        )
    )
    rules.append(
        _rule(
            "health",
            [
                "pharmacy",
                "cvs",
                "walgreens",
                "rite aid",
                "kaiser",
                "clinic",
                "hospital",
                "dental",
                "dentist",
                "optometr",
            ],
        )
    )
    return Registry(rules^)


# ── user-editable registry: parse + merge a config file ───────────────────────


def _valid_tag_name(name: String) -> Bool:
    """A tag name may contain spaces but must not be empty or contain a field
    separator — `,` (splits the stored comma-joined `.tags` column + the codegen
    tag list), `=` (the tag/keywords separator), tab or newline (TSV/line
    separators). Letting one through would silently split into phantom tags."""
    if name.byte_length() == 0:
        return False
    if "," in name or "=" in name or "\t" in name or "\n" in name:
        return False
    return True


def parse_rules(text: String) raises -> List[Rule]:
    """Parse user category rules from the config-file format. One rule per
    non-comment line:

        <tag> = <keyword>, <keyword>, ...

    matched case-insensitively as substrings. Blank lines and lines starting
    with `#` are ignored; tag/keywords are trimmed and empty keywords dropped
    (so a malformed line yields no rule rather than an error). Keywords must not
    contain `=` or `,` (the field separators). Excludes aren't exposed in the
    user format yet — every parsed rule is keyword-only."""
    var out = List[Rule]()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i].strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var parts = line.split("=")
        if len(parts) < 2:
            continue
        var tag = String(parts[0].strip())
        if not _valid_tag_name(tag):
            continue
        var kw_parts = String(parts[1]).split(",")
        var kws = List[String]()
        for k in range(len(kw_parts)):
            var kw = String(kw_parts[k].strip())
            if kw.byte_length() > 0:
                kws.append(kw^)
        if len(kws) > 0:
            out.append(Rule(tag^, kws^, List[String]()))
    return out^


def merge_registry(var base: Registry, extra: List[Rule]) raises -> Registry:
    """Merge `extra` rules into `base` (additive): keywords for a tag that
    already exists are APPENDED to that rule; a new tag is added as a new rule.
    So a user line `phone = my carrier` extends the built-in `phone`, and a new
    tag `pets = chewy, petco` creates a category. Built-in keywords are never
    removed (v1 is additive)."""
    for e in range(len(extra)):
        ref er = extra[e]
        var found = -1
        for b in range(len(base.rules)):
            if base.rules[b].tag == er.tag:
                found = b
                break
        if found >= 0:
            var r = base.rules[found].copy()
            for k in range(len(er.keywords)):
                r.keywords.append(er.keywords[k].copy())
            base.rules[found] = r^
        else:
            base.rules.append(er.copy())
    return base^


def tag_names(reg: Registry) raises -> List[String]:
    """The distinct tags the registry can assign, in registry order — what the
    codegen context advertises and the System tab lists."""
    var out = List[String]()
    for i in range(len(reg.rules)):
        out.append(reg.rules[i].tag.copy())
    return out^


def rules_canon(reg: Registry) -> String:
    """A deterministic, comment-free serialization of a registry's RULES — used to
    checksum "has the user changed the rules?" independent of comments/whitespace.
    `tag <TAB> kw1,kw2,… <NL>` per rule, in order; keywords verbatim (matching
    lowercases at match time, so case here is part of the rule's identity)."""
    var out = String("")
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        out += r.tag + "\t"
        for k in range(len(r.keywords)):
            if k > 0:
                out += ","
            out += r.keywords[k]
        out += "\n"
    return out^


def registry_to_text(reg: Registry, checksum: String) raises -> String:
    """Serialize a registry to the editable config-file format — the SOURCE OF
    TRUTH written to `~/.config/millfolio/categories.txt`. The built-in defaults
    are written out as real, editable `tag = kw, kw` lines (not hidden in the
    binary). The `# managed-checksum:` line records the rules we wrote, so the
    loader can tell an untouched file (auto-refresh the defaults on upgrade) from
    one the user has edited (leave it alone — it's authoritative)."""
    var out = String(
        "# millfolio category rules — THIS FILE IS THE SOURCE OF TRUTH; edit"
        " freely.\n# Format: <tag> = keyword, keyword, …   (case-insensitive"
        " substring match).\n# A tag name may contain spaces but not a comma or"
        " '=' (those are separators).\n# Lines starting with # are comments."
        " Re-run `mill index` after editing.\n#\n# The rules below are the"
        " built-in"
        " defaults. While you leave them unchanged\n# they auto-update on"
        " upgrade; once you edit any rule, the file is yours\n# and we won't"
        " overwrite it. Add your own categories by adding lines.\n#"
        " managed-checksum: "
    )
    out += checksum + "\n"
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        out += r.tag + " = "
        for k in range(len(r.keywords)):
            if k > 0:
                out += ", "
            out += r.keywords[k]
        out += "\n"
    return out^
