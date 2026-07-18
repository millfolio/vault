"""wiring — build the enclave VAULT harness.

Shared by the CLI (enclave.mojo) and the HTTP server (server.mojo) so both go
through one composition path. Kept out of enclave.mojo (which owns `main`) so
server.mojo can import it without pulling in a second `main`.
"""

from std.os import getenv, makedirs

from security import Budget
from settings import Config
from security import EgressGuard, ensure_canary, vault_fingerprints
from transport import LocalClient, RemoteClient
from security import Sandbox, SandboxPolicy
from security import CapabilityBroker
from harness import Harness
from vaultcfg import vault_index_dir


def mkdirs(path: String):
    """`mkdir -p`; an already-existing path is fine (the error is swallowed)."""
    try:
        makedirs(path)
    except:
        pass  # already exists, or created concurrently


def scratch_dir() -> String:
    """The sandbox scratch dir (always writable, created on use)."""
    return getenv("HOME", "") + "/.config/enclave/scratch"


def build_vault_harness(cfg: Config, vault_dir: String) raises -> Harness:
    """Wire the harness for the VAULT path (run_vault_task):

    - the sandbox policy is in "loopback" network mode with the vault dir as the
      (read-only) data dir + the LanceDB index dir read-allowed, so the run
      profile renders enclave-vault.sb.template (loopback-only egress);
    - the EgressGuard is ARMED from the real vault (security/seed.mojo): the
      persisted canary dotfile inside the vault dir (invisible to the trusted
      manifest/index walkers, which skip dotfiles — but sitting where a raw
      directory read by careless generated code picks it up) + fingerprints
      (the API key, the real vault path, PII-shaped values sampled from the
      CSVs' first rows). The manifest stays aliases-only by construction
      (millfolio/manifest.mojo); the armed guard is the tripwire proving it
      stays that way. Seeding is best-effort and the sampled values never
      leave process memory. (search/ask_local results never go upstream —
      they print locally.)"""
    var scratch = scratch_dir()
    mkdirs(scratch)

    var canaries = List[String]()
    var canary = ensure_canary(vault_dir)
    if canary.byte_length() > 0:
        canaries.append(canary^)
    var guard = EgressGuard(
        vault_fingerprints(vault_dir, cfg.api_key), canaries^
    )
    var local = LocalClient(cfg.local_url.copy(), cfg.local_model.copy())
    var remote = RemoteClient(
        cfg.remote_base_url.copy(),
        cfg.api_key.copy(),
        cfg.remote_model.copy(),
        cfg.mock,
        guard^,
    )
    var policy = SandboxPolicy(
        vault_dir.copy(), scratch.copy(), vault_index_dir(), String("loopback")
    )
    var sandbox = Sandbox(policy^, String("sandbox/enclave.sb.template"))

    var allowed = List[String]()
    allowed.append(String("vault_tools"))
    allowed.append(String("ask_local"))
    var broker = CapabilityBroker(allowed^)

    var budget = Budget(cfg.remote_token_budget)
    return Harness(
        local^, remote^, sandbox^, broker^, budget^, cfg.use_local_summary
    )
