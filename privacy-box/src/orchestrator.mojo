"""Orchestrator — privacy_box's core loop (pi's `pi-agent-core` equivalent).

VAULT-ONLY. Wires the layers into the privacy flow (README.md):

  1. `mill manifest` produces the ALIASED view (the only vault info the remote
     model sees — never a real name, value, or path).
  2. RemoteClient.codegen writes a `from vault import *` program from that (every
     outbound message passes the EgressGuard — confidentiality enforced here).
  3. compile it (with the millfolio include paths), looping the fix on COMPILE
     errors only; the code is in terms of aliases, so there is no dealias step.
  4. run the program in the loopback Sandbox over REAL data; only the printed
     answer surfaces. search()/ask_local() reach 127.0.0.1 only.

See run_vault_task for the full confidentiality argument.
"""

from std.os import getenv, setenv
from logging import log

from security import Budget
from transport import (
    LocalClient,
    RemoteClient,
    ChatMessage,
    _codegen_system,
    DeltaSink,
)
from security import Sandbox, RunHandle
from security import CapabilityBroker
from vaultcfg import millfolio_bin, vault_include_paths

# The tag-registry READ layer, shared IN-PROCESS with the CLI + app server. It's
# LanceDB- and network-free (no flare/HTTP), so pulling it into the sandbox
# orchestrator keeps the trust surface small — and lets codegen read tags without
# spawning the CLI binary.
from vault.derive.tags import codegen_tags_describe


# The progress-line sentinel — MUST match `vault.progress` in vault/core/src/vault.mojo
# (which can't be imported here: vault is only on the *generated* program's include
# path, not privacy-box's). The server imports THIS constant so it can't drift from
# the orchestrator. Keep all three copies of the literal in lockstep.
comptime PROGRESS_SENTINEL = "\x1f@@progress@@\x1f"
comptime STAT_SENTINEL = "\x1f@@stat@@\x1f"
# On-device-model exchange line (debug; gated by $MILLFOLIO_LOG_LOCAL). Matches the
# copy in vault tools.mojo — the server streams these as collapsible debug items.
comptime LOCAL_SENTINEL = "\x1f@@local@@\x1f"
comptime LOCAL_SEP = "\x1f=>\x1f"  # separates <sent> from <got> in a LOCAL line
# The declarative RESULT SPEC line (COMPUTE_VS_RENDER.md, Phase 1). A program that
# uses the `result_text`/`kpi`/`table`/`series` builders emits its serialized `v:1`
# spec on a `RESULT_SENTINEL + <json>` line. MUST match `vault.result.RESULT_SENTINEL`
# (only on the *generated* program's include path, not here). `_strip_progress` drops
# it from the captured answer text; the WS server captures it separately (from the
# poll stream) and attaches it to the message event.
comptime RESULT_SENTINEL = "\x1f@@result@@\x1f"


def _strip_progress(out_text: String) raises -> String:
    """Drop the internal sentinel lines (live progress + per-engine-call timing)
    from captured stdout, leaving only the program's real answer text. Used by both
    `vault_run` (CLI) and `vault_run_finish` (WS) so the streamed progress/stats
    don't pollute the final reply."""
    var lines = out_text.split("\n")
    var kept = String("")
    var first = True
    for i in range(len(lines)):
        var ln = String(lines[i])
        if (
            ln.startswith(String(PROGRESS_SENTINEL))
            or ln.startswith(String(STAT_SENTINEL))
            or ln.startswith(String(LOCAL_SENTINEL))
            or ln.startswith(String(RESULT_SENTINEL))
        ):
            continue
        if not first:
            kept += "\n"
        kept += ln
        first = False
    return kept^


def _session_append(text: String):
    """Append `text` to the session transcript at $MILLFOLIO_SESSION_LOG (set by the
    CLI per `ask`), best-effort. Captures the full outside-model exchange — prompt
    + program — for after-the-fact inspection. No-op when the env var is unset.
    """
    var path = getenv("MILLFOLIO_SESSION_LOG", "")
    if path == "":
        return
    try:
        with open(path, "a") as f:  # append mode (validated); creates if absent
            f.write(text)
    except:
        pass


comptime _NO_REMOTE_MSG = (
    "This question needs the frontier model to write its program, but no remote"
    " budget is available — set ANTHROPIC_API_KEY and retry."
)


def _tags_context(tags: String) raises -> String:
    """Format the available-tags block for the codegen prompt, or empty when there
    are none. `tags` is one `name <TAB> description` per line (from `millfolio
    tags --describe`). Renders a bulleted `- name — description` list + the rule
    that the model must pick a tag ONLY when its description clearly fits —
    otherwise propose a new one. The description is what stops the `gym` → `health`
    misfire: the model sees `health — … NOT gyms/fitness` and won't force it. Never
    the keyword rules (on-device detail; they hold merchant strings the user typed).
    """
    if tags.byte_length() == 0:
        return String("")
    var bullets = String("")
    var lines = tags.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if String(line.strip()).byte_length() == 0:
            continue
        var parts = line.split("\t")
        var name = String(String(parts[0]).strip())
        if name.byte_length() == 0:
            continue
        bullets += "\n- " + name
        if len(parts) > 1:
            var desc = String(String(parts[1]).strip())
            if desc.byte_length() > 0:
                bullets += " — " + desc
    if bullets.byte_length() == 0:
        return String("")
    return (
        "\n\nAvailable category tags — each Txn's `.tags` is drawn from these."
        ' Filter transactions() on a tag for category questions (e.g. `"phone"'
        " in t.tags`), but ONLY when its description clearly fits the question."
        " If none fits, do NOT force a near-match — propose a new tag"
        " (# SUGGEST_TAG) or classify inline:"
        + bullets
    )


struct Orchestrator(Movable):
    var local: LocalClient
    var remote: RemoteClient
    var sandbox: Sandbox
    var broker: CapabilityBroker
    var budget: Budget  # remote-API token budget; routes to local when depleted
    var use_local_summary: Bool  # have the local model summarize the result
    var max_fix_attempts: Int  # compile-feedback retries (compile errors only) before giving up

    def __init__(
        out self,
        var local: LocalClient,
        var remote: RemoteClient,
        var sandbox: Sandbox,
        var broker: CapabilityBroker,
        var budget: Budget,
        use_local_summary: Bool,
    ):
        self.local = local^
        self.remote = remote^
        self.sandbox = sandbox^
        self.broker = broker^
        self.budget = budget^
        self.use_local_summary = use_local_summary
        self.max_fix_attempts = 6

    def _codegen(mut self, messages: List[ChatMessage]) raises -> String:
        """Code generation runs on the REMOTE frontier model ONLY. The on-device
        model isn't capable enough to write correct vault programs (it ignores the
        tag list, hand-rolls raw CSV columns, mislabels output), so with no remote
        budget we FAIL LOUDLY rather than emit a bad local program. Charges the
        budget by the remote token cost."""
        if self.budget.depleted():
            raise Error(_NO_REMOTE_MSG)
        var g = self.remote.codegen(messages)
        self.budget.charge(g.tokens)
        return g.code.copy()

    def _fix(mut self, code: String, errors: String) raises -> String:
        """Compile-fix is codegen too — frontier model only (same reason as
        `_codegen`); raise if the budget ran out mid-run."""
        if self.budget.depleted():
            raise Error(_NO_REMOTE_MSG)
        var g = self.remote.fix_code(code, errors)
        self.budget.charge(g.tokens)
        return g.code.copy()

    # ── vault pipeline (steps) ──────────────────────────────────────────────────
    # The full flow is run_vault_task; it's split into these public steps so the
    # streaming WS server (app/server) can emit status/debug between them and gate
    # step 4 on the user's approval. The CLI + the unary HTTP server call
    # run_vault_task and are unaffected.

    def vault_manifest(mut self, vault_dir: String) raises -> String:
        """Step 1 — the ALIASED, frontier-safe manifest. Shell out to the trusted
        `mill manifest <vault_dir>` and capture its stdout. This is the ONLY
        vault info that reaches the remote model, aliases-only by construction.
        """
        log("• aliasing the vault manifest (the frontier-safe view)…")
        var dac = millfolio_bin()
        var manifest_argv: List[String] = [dac, String("manifest"), vault_dir]
        var m = self.sandbox.capture(manifest_argv)
        if m.exit_code != 0:
            raise Error(
                "vault: `mill manifest` failed (is millfolio built at "
                + dac
                + "? try `pixi run build` in millfolio). Output:\n"
                + m.output
            )
        # Strip the leading "vault: <abs path>" line `mill manifest` prints. That path
        # is host-specific (…/<dev-home>/… vs …/<demo-account>/…) and the manifest is
        # embedded verbatim in the codegen prompt — so leaking it (a) violates the
        # aliases-only confidentiality invariant and (b) makes the replay-cache key
        # host-specific, so a cache primed on one machine never hits on another. The
        # model only needs the aliased file list that follows.
        var lines = m.output.split("\n")
        if len(lines) > 0 and String(lines[0]).startswith("vault:"):
            var out = String("")
            for i in range(1, len(lines)):
                if i > 1:
                    out += "\n"
                out += String(lines[i])
            return out^
        return m.output.copy()

    def _vault_tags(mut self) raises -> String:
        """The effective category tags for codegen — `name <TAB> description` per
        line for every deterministic tag plus the fully-backfilled ML tags (the
        readiness gate), read IN-PROCESS from the shared LanceDB-/network-free
        registry layer (`vault.derive.tags`) — no CLI spawn. Only tag NAMES +
        scope notes reach the model, NEVER the keyword rules (on-device matching
        detail that can hold merchant names the user typed).

        HARD-FAIL by design: tags are a critical part of the answer surface and
        there isn't enough compute for interactive ML exploration, so if the
        registry can't be read this RAISES rather than letting codegen proceed
        tag-blind (which would silently mis-answer category questions)."""
        return String(codegen_tags_describe().strip())

    def vault_codegen(
        mut self, question: String, manifest: String
    ) raises -> String:
        """Step 2 — ask the model (budget-routed; EgressGuard-checked inside
        _codegen) for a `from vault import *` program from the question + the
        aliased manifest. The system prompt is resources/privacy_box-system.md.
        """
        # Codegen is frontier-only now — fail fast with a clear message rather than
        # emit a bad on-device program.
        if self.budget.depleted():
            log(
                "• no remote budget — cannot write the program (need a frontier"
                " model)"
            )
            raise Error(_NO_REMOTE_MSG)
        log("• asking the frontier model to write the program…")
        var tags = self._vault_tags()
        if tags.byte_length() > 0:
            log("• category tags + scope notes sent to the model")
        var user_msg = (
            String("Question: ")
            + question
            + "\n\nVault manifest (aliases only — you never see real"
            " content):\n"
            + manifest
            + _tags_context(tags)
            + "\n\nWrite the Mojo program (`from vault import *`) that"
            " answers it."
        )
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("user"), user_msg))
        var code = self._codegen(msgs)
        _session_append(
            "QUESTION: "
            + question
            + "\n\n===== SYSTEM PROMPT =====\n"
            + _codegen_system()
            + "\n\n===== PROMPT TO THE OUTSIDE MODEL (user turn) =====\n"
            + user_msg
            + "\n\n===== OUTSIDE MODEL OUTPUT (program) =====\n"
            + code
            + "\n"
        )
        return code

    def vault_codegen_stream[
        S: DeltaSink
    ](
        mut self, question: String, manifest: String, mut sink: S
    ) raises -> String:
        """Like `vault_codegen` but STREAMS the program to `sink` (live UI). Streams
        from the remote frontier model; with no remote budget it FAILS (codegen is
        frontier-only). Same EgressGuard gate + session transcript."""
        if self.budget.depleted():
            log(
                "• no remote budget — cannot write the program (need a frontier"
                " model)"
            )
            raise Error(_NO_REMOTE_MSG)
        log("• asking the frontier model to write the program (streaming)…")
        var tags = self._vault_tags()
        if tags.byte_length() > 0:
            log("• category tags + scope notes sent to the model")
        var user_msg = (
            String("Question: ")
            + question
            + "\n\nVault manifest (aliases only — you never see real"
            " content):\n"
            + manifest
            + _tags_context(tags)
            + "\n\nWrite the Mojo program (`from vault import *`) that"
            " answers it."
        )
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("user"), user_msg))
        # Budget was checked above (frontier-only); stream from the remote model.
        var g = self.remote.codegen_stream(msgs, sink)
        self.budget.charge(g.tokens)
        var code = g.code.copy()
        _session_append(
            "QUESTION: "
            + question
            + "\n\n===== SYSTEM PROMPT =====\n"
            + _codegen_system()
            + "\n\n===== PROMPT TO THE OUTSIDE MODEL (user turn) =====\n"
            + user_msg
            + "\n\n===== OUTSIDE MODEL OUTPUT (program) =====\n"
            + code
            + "\n"
        )
        return code

    def vault_build(mut self, code: String) raises -> Int:
        """Step 3 — compile with the vault include paths, looping the fix on
        COMPILE errors ONLY (the code is aliased, so compiler errors are safe to
        feed back; a RUNTIME error could carry real content and is never sent
        upstream). Leaves the compiled binary in scratch; raises if it never
        compiles. Returns the number of fix attempts (frontier fix calls made) so
        the caller can surface it in the run stats."""
        log("• compiling the generated program…")
        var work = code.copy()
        var includes = vault_include_paths()
        var compiled = self.sandbox.compile(work, includes)
        var attempt = 0
        while compiled.exit_code != 0 and attempt < self.max_fix_attempts:
            work = self._fix(
                work, compiled.output
            )  # budget-routed; guarded; aliased
            compiled = self.sandbox.compile(work, includes)
            attempt += 1
        if compiled.exit_code != 0:
            raise Error(
                "vault: generated program did not compile after "
                + String(self.max_fix_attempts)
                + " fix attempt(s). Last error:\n"
                + compiled.output
            )
        return attempt

    def vault_run(mut self, vault_dir: String) raises -> String:
        """Step 4 — run the compiled binary in the LOOPBACK sandbox over the REAL
        data (network-denied EXCEPT 127.0.0.1, so search()/ask_local() reach the
        local models but the program cannot phone home). MILLFOLIO_VAULT points the
        tools at the vault dir. Returns stdout (print_answer) — local; a runtime
        error surfaces here and is NEVER fed upstream."""
        log("• running it locally over your vault…")
        # setenv is process-global and NOT thread-safe: with multiple server workers a
        # per-run setenv races other threads' getenv and corrupts environ, hanging the
        # next posix_spawn. Only write when it actually changes (a no-op after the first
        # run / when the launcher already exports MILLFOLIO_VAULT) — no realloc, no race.
        if String(getenv("MILLFOLIO_VAULT", "")) != vault_dir:
            _ = setenv("MILLFOLIO_VAULT", vault_dir, True)
        var bin = self.sandbox.scratch_bin()
        var out = self.sandbox.run(bin, List[String]()).output.copy()
        _session_append(
            "\n===== RESULT (local — never sent upstream) =====\n" + out + "\n"
        )
        # Strip the internal progress/stat sentinel lines so the CLI reply is just
        # the program's answer (the WS path streams those live instead).
        return _strip_progress(out)

    # ── streaming run (steps 4a–4d) ──────────────────────────────────────────────
    # The blocking `vault_run` above stays for the CLI / run_vault_task. The WS
    # server drives the run NON-BLOCKING via these four so it can stream each
    # `progress(...)` line the generated program emits, live, while the child runs.
    # Confinement is unchanged — `run_start` renders the SAME vault profile.

    def vault_run_start(mut self, vault_dir: String) raises -> RunHandle:
        """Step 4a — point the tools at the vault dir and SPAWN the compiled binary
        in the loopback sandbox without blocking. Returns a handle to poll/reap.
        """
        log("• running it locally over your vault…")
        # setenv is process-global and NOT thread-safe: with multiple server workers a
        # per-run setenv races other threads' getenv and corrupts environ, hanging the
        # next posix_spawn. Only write when it actually changes (a no-op after the first
        # run / when the launcher already exports MILLFOLIO_VAULT) — no realloc, no race.
        if String(getenv("MILLFOLIO_VAULT", "")) != vault_dir:
            _ = setenv("MILLFOLIO_VAULT", vault_dir, True)
        var bin = self.sandbox.scratch_bin()
        return self.sandbox.run_start(bin, List[String]())

    def vault_run_poll(mut self, mut h: RunHandle) raises -> List[String]:
        """Step 4b — the complete stdout lines emitted since the last poll (progress
        sentinels still attached; the caller filters)."""
        return self.sandbox.run_poll(h)

    def vault_run_reap(self, h: RunHandle) -> Int:
        """Step 4c — non-blocking reap: -1 still running, -2 error, else exit code.
        """
        return self.sandbox.run_reap(h)

    def vault_run_finish(self, h: RunHandle) raises -> String:
        """Step 4d — the full captured stdout, with progress lines stripped, as the
        reply. Mirrors `vault_run`'s session-log side effect (the FULL output,
        including progress, goes to the transcript for inspection)."""
        var out = self.sandbox.run_finish(h)
        _session_append(
            "\n===== RESULT (local — never sent upstream) =====\n" + out + "\n"
        )
        return _strip_progress(out)

    def run_vault_program(
        mut self, program: String, vault_dir: String
    ) raises -> String:
        """Run a SUPPLIED `from vault import *` program (from `mill run <file/URL>`,
        NOT the model) through the EXACT same compile + Seatbelt + capture path a
        generated program takes — same include paths (`vault_include_paths`), same
        loopback run profile, same `_strip_progress`/result-spec handling. There is
        NO codegen, NO manifest, NO remote budget, and — deliberately — NO model
        FIX loop: a user program may embed real content, so a compile error is
        surfaced LOCALLY and NEVER fed upstream (unlike `vault_build`, whose
        aliased-only errors are safe to send to the model).

        The program is UNTRUSTED exactly like model output, so it runs in the
        IDENTICAL loopback Seatbelt profile (network-denied except 127.0.0.1,
        writes confined to scratch) — `vault_run` renders the same vault profile
        `run_vault_task` uses. No relaxation."""
        log("• compiling the supplied program…")
        var includes = vault_include_paths()
        var compiled = self.sandbox.compile(program, includes)
        if compiled.exit_code != 0:
            raise Error(
                "vault: the supplied program did not compile:\n"
                + compiled.output
            )
        _session_append(
            "===== SUPPLIED PROGRAM (mill run — not model-written) =====\n"
            + program
            + "\n"
        )
        return self.vault_run(vault_dir)

    def run_vault_task(
        mut self, question: String, vault_dir: String
    ) raises -> String:
        """Answer a question about the private vault by writing ONE Mojo program
        that does `from vault import *` and calls the vault tools, compiling it
        with the millfolio include paths, and running it in the loopback sandbox
        over the REAL data. Only the printed answer surfaces.

        This is the existing confidentiality model extended from "read one CSV" to
        "use the vault tools". The CONFIDENTIALITY INVARIANT, held end to end:

          - The ONLY vault information that reaches the remote (frontier) model is
            the ALIASED manifest (`file_0 [csv] 130 bytes  schema: col_0, col_1`)
            produced by `mill manifest` — aliases/kinds/sizes/aliased columns,
            never a real name, value, or path (see millfolio/src/manifest.mojo).
          - The question is the user's to send; the data is not. Every outbound
            message still passes the EgressGuard inside codegen()/fix_code()
            (fails closed) — a real value leaking into the manifest would trip it.
          - The generated program is written in terms of ALIASES (the tools TAKE
            aliases and resolve them locally), so there is NO dealias step — and
            nothing real is ever injected into the code (unlike the CSV path).
          - The program runs locally; search()/ask_local() hit ONLY 127.0.0.1
            (the loopback-only run profile, privacy_box-vault.sb.template, denies all
            other network); the answer is printed locally and returned here.

        So: aliases out, code back, run local over real data, answer local. The
        real content is touched only by the on-device tools, never the frontier.

        Auto-approved wrapper over the steps above; the WS server runs the steps
        directly to stream status/debug and gate the run on user approval."""
        var manifest = self.vault_manifest(vault_dir)
        var code = self.vault_codegen(question, manifest)
        _ = self.vault_build(code)
        return self.vault_run(vault_dir)
