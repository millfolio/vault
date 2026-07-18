"""state — the shared server state struct.

`MillfolioState` (the vault orchestrator + served vault dir) lived inline in
`server.mojo`. It's extracted here so the per-domain handler modules
(`handlers_*`) can take a `UnsafePointer[MillfolioState, MutUntrackedOrigin]`
without importing back into `server.mojo` (which would be a cycle — `server`
imports the handler modules). Only depends on `orchestrator`, so it stays an
independent leaf.

Pure move out of server.mojo — behaviour is identical.
"""

from harness import Harness


struct MillfolioState(Movable):
    """The vault orchestrator + vault dir, loaded once and reached by the
    (borrowed-self) handler through a pointer so `run_vault_task` can still take
    `mut self`. `/chat` always runs `run_vault_task` over `vault_dir`."""

    var harness: Harness
    var vault_dir: String

    def __init__(out self, var harness: Harness, var vault_dir: String):
        self.harness = harness^
        self.vault_dir = vault_dir^
