"""Security — privacy_box's trust boundary, grouped so it audits in isolation.

The CONTAINMENT + CONFIDENTIALITY surface of the harness lives here, and NOWHERE
else: the four modules below are the entire mechanism that keeps generated code
boxed and keeps real data off the wire. Reviewing this sub-package (plus the
`sandbox/` profile templates it renders) is reviewing the whole security posture.

  • sandbox — CONTAINMENT: renders the `sandbox-exec` profile and runs a binary
    under it (posix_spawn, no shell), the box generated code cannot escape.
  • egress  — CONFIDENTIALITY: the single outbound chokepoint toward the remote
    model; canary/fingerprint tripwires + PII redaction, fails CLOSED.
  • broker  — the minimal capability allowlist generated code may call (no raw
    file handles or sockets — attack surface kept tiny).
  • budget  — the token budget for EXTERNAL (frontier) calls; on depletion the
    orchestrator degrades to the LOCAL model instead of unbounded spend.

ACYCLIC: this sub-package depends only on leaf modules (`vaultcfg`, `logging`,
stdlib) — never back on `orchestrator`/`transport`/`wiring`/`privacy_box`, so the
boundary can't be short-circuited through a dependency cycle. Importers pull the
public surface via `from security import …` (or `from security.sandbox import …`
to reach an in-module test helper).
"""

from security.sandbox import (
    Sandbox,
    SandboxPolicy,
    RunHandle,
    RunResult,
)
from security.egress import EgressGuard
from security.broker import (
    CapabilityBroker,
    Result,
)
from security.budget import (
    Budget,
    parse_budget,
)
