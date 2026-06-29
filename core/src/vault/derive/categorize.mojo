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
