<script lang="ts">
  import { onMount } from "svelte";
  import type { StepState } from "$lib/protocol";

  // One inline timeline: chat bubbles (user/assistant), plus the workflow events
  // rendered in place — status/debug small, approval at regular font. Mirrors the
  // ChatItem union in routes/+page.svelte.
  interface Item {
    kind: "user" | "assistant" | "status" | "debug" | "approval" | "tags";
    id: string;
    text?: string;
    tags?: string;         // tags: comma-joined category tags the program filtered on
    stepId?: string;
    label?: string;
    state?: StepState;
    detail?: string;
    title?: string;
    body?: string;
    language?: string;
    resolved?: "approved" | "rejected";
    source?: string;       // assistant: filename of the doc used to answer
    sourceAlias?: string;  // …its alias → /api/doc?alias=<sourceAlias>
  }

  let {
    items,
    busy,
    demo = false,
    onsend,
    onapprove,
    onreject,
  }: {
    items: Item[];
    busy: boolean;
    demo?: boolean;
    onsend: (text: string) => void;
    onapprove: (id: string, stepId: string) => void;
    onreject: (id: string, stepId: string) => void;
  } = $props();

  // The curated demo questions — the ONLY ones the replay cache can answer. The
  // authoritative list is the primed questions.json (the survivors of prime-cache.sh),
  // fetched at runtime so the dropdown stays in sync with the cache without duplicating
  // it here. The inline list is just a fallback when /questions.json can't be fetched.
  let SUGGESTED = $state<string[]>([
    "how many transactions do I have",
    "what is the total of my transactions",
    "what kinds of files are in my vault",
    "how much did I spend",
  ]);
  onMount(() => {
    loadRecent();
    loadHistory(); // durable backend history (no-op in demo)
    if (!demo) return;
    fetch("/questions.json")
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((qs) => {
        if (Array.isArray(qs) && qs.length) SUGGESTED = qs as string[];
      })
      .catch(() => {}); // keep the fallback list
  });

  let draft = $state("");
  let picked = $state("");
  let stream = $state<HTMLDivElement>();

  // Question history — shown in a left panel when the question box is focused.
  // EVERY ask is kept forever. The durable copy lives in the BACKEND store
  // (`asks.jsonl`, surfaced at /api/history): each record carries the question,
  // the generated program, and the answer, so the history survives a browser-data
  // clear and follows the vault, not the device. localStorage is a fast, offline
  // fallback (question text only) merged in for asks the backend hasn't recorded
  // yet (the record lands only after the answer completes). Newest-first, deduped.
  interface AskRecord {
    q: string;
    answer?: string;
    code?: string;
    source?: string;
    ts?: number;
  }
  const RECENT_KEY = "millfolio:recent-questions";
  let recent = $state<AskRecord[]>([]);
  let showHistory = $state(false);
  let inputEl = $state<HTMLInputElement>();

  // Merge two record lists, newest-first, deduped by question — the FIRST occurrence
  // wins, so callers pass the richer source (backend, with code+answer) first.
  function mergeRecent(...lists: AskRecord[][]): AskRecord[] {
    const seen = new Set<string>();
    const out: AskRecord[] = [];
    for (const list of lists)
      for (const r of list) {
        if (!r?.q || seen.has(r.q)) continue;
        seen.add(r.q);
        out.push(r);
      }
    return out;
  }
  function localQuestions(): AskRecord[] {
    try {
      const raw = localStorage.getItem(RECENT_KEY);
      if (raw) {
        const a = JSON.parse(raw);
        if (Array.isArray(a))
          return a.filter((x) => typeof x === "string").map((q) => ({ q }));
      }
    } catch {} // private mode / quota — just start empty
    return [];
  }
  function loadRecent() {
    recent = localQuestions();
  }
  // Pull the durable history from the backend and merge it over the local cache
  // (backend records win — they carry code+answer). Demo has no backend → skip.
  async function loadHistory() {
    if (demo) return;
    try {
      const r = await fetch("/api/history");
      if (!r.ok) return;
      const data = await r.json();
      const recs: AskRecord[] = (data?.records ?? []).map((x: any) => ({
        q: String(x.q ?? ""),
        answer: x.answer,
        code: x.code,
        source: x.source,
        ts: x.ts,
      }));
      recent = mergeRecent(recs, recent);
    } catch {} // offline / older server without /api/history — keep the local list
  }
  function remember(q: string) {
    // Optimistic: show it immediately (the backend records it once the answer is in).
    recent = mergeRecent([{ q }], recent);
    try {
      localStorage.setItem(RECENT_KEY, JSON.stringify(recent.map((r) => r.q)));
    } catch {}
  }
  // Pick a past question → drop it into the box to edit/resend (non-destructive).
  function pickRecent(q: string) {
    draft = q;
    showHistory = false;
    inputEl?.focus();
  }

  // Demo auto-approve: the public demo shouldn't park on the "Approve" gate (the
  // single-threaded server would wedge), so in demo mode an unresolved approval gets
  // a 15s countdown and then auto-approves. "+1 min" extends it for a closer look.
  // (The real product keeps manual approval — gated on `demo`.)
  const AUTO_APPROVE_SECS = 15;
  let remaining = $state(0); // seconds left on the current auto-approve countdown
  // The id of the approval currently awaiting a decision (null if none). $derived so it
  // recomputes reactively for EVERY question, not just the first.
  const pendingApprovalId = $derived<string | null>(
    demo ? ([...items].reverse().find((x) => x.kind === "approval" && !x.resolved)?.id ?? null) : null,
  );
  function bumpTimer() {
    remaining += 60;
  }
  // One countdown per pending approval; the effect's cleanup clears the interval when
  // the pending id changes (next question) or the component unmounts.
  $effect(() => {
    const id = pendingApprovalId;
    if (!id) return;
    remaining = AUTO_APPROVE_SECS;
    const h = setInterval(() => {
      remaining -= 1;
      if (remaining <= 0) {
        clearInterval(h);
        const step = items.find((x) => x.id === id)?.stepId ?? "";
        onapprove(id, step);
      }
    }, 1000);
    return () => clearInterval(h);
  });

  const icon: Record<StepState, string> = {
    pending: "○",
    running: "◐",
    "awaiting-approval": "⏸",
    done: "●",
    error: "✕",
  };

  // Auto-scroll to the newest item.
  $effect(() => {
    void items.length;
    if (stream) stream.scrollTop = stream.scrollHeight;
  });

  // Live elapsed time on the currently-running step. The codegen step ("Writing the
  // program") is a 30s+ BLOCKING call to the frontier model with no intermediary data,
  // so without this it just looks hung. Frontend-only: key the timer on the active
  // step's id (a string, so the effect only resets when the step actually changes —
  // not on every items update) and tick until the next event replaces it.
  const activeStepId = $derived<string | null>(
    busy
      ? ([...items].reverse().find((x) => x.kind === "status" && x.state === "running")?.id ?? null)
      : null,
  );
  let stepElapsed = $state(0);
  $effect(() => {
    const id = activeStepId;
    if (!id) { stepElapsed = 0; return; }
    const t0 = Date.now();
    stepElapsed = 0;
    const h = setInterval(() => { stepElapsed = Math.floor((Date.now() - t0) / 1000); }, 1000);
    return () => clearInterval(h);
  });
  function fmtElapsed(s: number): string {
    return s < 60 ? `${s}s` : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  }

  // When an ask finishes (busy true→false), the backend has just written its record
  // (question + generated program + answer) — pull it so the history entry upgrades
  // from question-only to the full stored detail.
  let wasBusy = false;
  $effect(() => {
    if (wasBusy && !busy) loadHistory();
    wasBusy = busy;
  });

  function submit(e: SubmitEvent) {
    e.preventDefault();
    const t = draft.trim();
    if (!t || busy) return;
    onsend(t);
    remember(t);
    draft = "";
    showHistory = false;
  }

  // Demo: ask the selected curated question (only these are in the replay cache).
  function submitPicked(e: SubmitEvent) {
    e.preventDefault();
    if (!picked || busy) return;
    onsend(picked);
    picked = "";
  }
</script>

<section class="chat">
  {#if !demo && showHistory}
    <!-- click anywhere outside the panel to dismiss -->
    <div class="hist-backdrop" role="presentation" onclick={() => (showHistory = false)}></div>
    <aside class="history" aria-label="Questions you've asked">
      <div class="hist-head">
        <span>Recent questions</span>
        <button class="hist-close" type="button" aria-label="Close" onclick={() => (showHistory = false)}>×</button>
      </div>
      <ul>
        {#each recent as r}
          <li>
            {#if r.answer || r.code}
              <!-- backend record: expandable to its stored answer + generated program -->
              <details class="hist-rec">
                <summary title={r.q}>{r.q}</summary>
                {#if r.answer}<p class="hist-answer">{r.answer}</p>{/if}
                {#if r.source}<p class="hist-src">📄 {r.source}</p>{/if}
                {#if r.code}
                  <details class="hist-code">
                    <summary>generated program</summary>
                    <pre><code>{r.code}</code></pre>
                  </details>
                {/if}
                <button type="button" class="hist-use" onclick={() => pickRecent(r.q)}>Ask again</button>
              </details>
            {:else}
              <button type="button" class="hist-item" title={r.q} onclick={() => pickRecent(r.q)}>{r.q}</button>
            {/if}
          </li>
        {/each}
      </ul>
    </aside>
  {/if}
  <div class="stream" bind:this={stream}>
    <div class="thread">
    {#if items.length === 0}
      <p class="empty">Ask a question about the files in your vault</p>
    {/if}
    {#each items as it (it.id)}
      {#if it.kind === "user" || it.kind === "assistant"}
        <div class="msg {it.kind}">
          <span class="who">{it.kind === "user" ? "you" : "millfolio"}</span>
          <p>{it.text}</p>
          {#if it.kind === "assistant" && it.source && it.sourceAlias}
            <p class="source">
              📄 Source:
              <a href="/api/doc?alias={it.sourceAlias}" target="_blank" rel="noopener">{it.source}</a>
            </p>
          {/if}
        </div>
      {:else if it.kind === "status"}
        <div class="status {it.state}">
          <span class="icon" aria-hidden="true">{icon[it.state ?? "pending"]}</span>
          <span class="label">{it.label}</span>
          {#if it.detail}<span class="detail">— {it.detail}</span>{/if}
          {#if it.id === activeStepId && stepElapsed >= 2}<span class="elapsed">· {fmtElapsed(stepElapsed)}</span>{/if}
        </div>
      {:else if it.kind === "tags"}
        <div class="tagsused" title="The answer was computed by filtering your transactions on these category tags">
          <span class="tlabel">filtered by tag</span>
          {#each (it.tags ?? "").split(",") as t}<span class="chip">{t}</span>{/each}
        </div>
      {:else if it.kind === "debug"}
        <details class="debug">
          <summary>{it.title}</summary>
          <pre><code>{it.body}</code></pre>
        </details>
      {:else if it.kind === "approval"}
        <div class="approval">
          <p class="atitle">{it.title}</p>
          {#if it.body}<pre><code>{it.body}</code></pre>{/if}
          {#if it.resolved}
            <p class="decision {it.resolved}">
              {it.resolved === "approved" ? "✓ Approved" : "✕ Rejected"}
            </p>
          {:else}
            <div class="actions">
              <button class="approve" onclick={() => onapprove(it.id, it.stepId ?? "")}>
                {#if demo && it.id === pendingApprovalId}Approve ({remaining}s){:else}Approve{/if}
              </button>
              {#if demo && it.id === pendingApprovalId}
                <button class="bump" onclick={bumpTimer} title="Give yourself another minute to review">+1 min</button>
              {/if}
              <button class="reject" onclick={() => onreject(it.id, it.stepId ?? "")}>Reject</button>
            </div>
          {/if}
        </div>
      {/if}
    {/each}
    {#if busy}
      <div class="working" aria-live="polite">
        <span class="spin" aria-hidden="true"></span>working…
      </div>
    {/if}
    </div>
  </div>

  {#if demo}
    <form onsubmit={submitPicked}>
      <div class="row">
        <select bind:value={picked} disabled={busy} aria-label="Pick a question">
          <option value="" disabled>Pick a demo question…</option>
          {#each SUGGESTED as q}
            <option value={q}>{q}</option>
          {/each}
        </select>
        <button type="submit" disabled={busy || !picked}>Ask</button>
      </div>
    </form>
  {:else}
    <form onsubmit={submit}>
      <div class="row">
        <input
          type="text"
          placeholder="My question is…"
          bind:value={draft}
          bind:this={inputEl}
          disabled={busy}
          onfocus={() => (showHistory = recent.length > 0)}
          onkeydown={(e) => { if (e.key === "Escape") showHistory = false; }}
        />
        <button type="submit" disabled={busy || !draft.trim()}>Send</button>
      </div>
    </form>
  {/if}
</section>

<style>
  .chat {
    display: flex;
    flex-direction: column;
    min-height: 0;
    background: var(--surface);
    position: relative; /* positioning context for the recent-questions panel */
  }

  /* ── recent-questions panel (opens on focusing the question box) ─────────── */
  .hist-backdrop {
    position: absolute;
    inset: 0;
    z-index: 5; /* below the panel, above the conversation — catches outside clicks */
  }
  .history {
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    z-index: 6;
    width: min(280px, 80%);
    display: flex;
    flex-direction: column;
    background: var(--surface-2);
    border-right: 1px solid var(--border);
    box-shadow: 2px 0 12px rgba(0, 0, 0, 0.18);
    overflow-y: auto;
    animation: hist-in 0.14s ease-out;
  }
  @keyframes hist-in {
    from { transform: translateX(-8px); opacity: 0; }
  }
  .hist-head {
    position: sticky;
    top: 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 10px 12px;
    background: var(--surface-2);
    border-bottom: 1px solid var(--border);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-dim);
  }
  .hist-close {
    background: none;
    border: none;
    color: var(--text-dim);
    font-size: 18px;
    line-height: 1;
    cursor: pointer;
    padding: 0 2px;
  }
  .hist-close:hover { color: var(--text); }
  .history ul {
    list-style: none;
    margin: 0;
    padding: 6px;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .hist-item {
    width: 100%;
    text-align: left;
    background: none;
    border: none;
    color: var(--text);
    padding: 8px 10px;
    border-radius: var(--radius);
    cursor: pointer;
    font: inherit;
    font-size: 13px;
    /* one-line, ellipsised — the full question is in the title tooltip */
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .hist-item:hover { background: var(--surface); }
  /* backend record — expandable to its stored answer + generated program */
  .hist-rec {
    border-radius: var(--radius);
  }
  .hist-rec > summary {
    list-style: none;
    cursor: pointer;
    padding: 8px 10px;
    border-radius: var(--radius);
    color: var(--text);
    font-size: 13px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .hist-rec > summary::-webkit-details-marker { display: none; }
  .hist-rec > summary:hover { background: var(--surface); }
  .hist-rec[open] > summary {
    white-space: normal;
    font-weight: 600;
  }
  .hist-answer {
    margin: 4px 10px 6px;
    padding: 6px 8px;
    background: var(--surface);
    border-radius: var(--radius);
    font-size: 12.5px;
    color: var(--text);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .hist-src {
    margin: 0 10px 6px;
    font-size: 11px;
    color: var(--text-dim);
  }
  .hist-code {
    margin: 0 10px 6px;
    font-size: 11px;
  }
  .hist-code > summary {
    cursor: pointer;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-size: 10px;
  }
  .hist-code pre {
    margin: 4px 0 0;
    padding: 8px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    max-height: 40vh;
    overflow: auto;
    font-size: 11px;
  }
  .hist-use {
    margin: 2px 10px 8px;
    padding: 5px 12px;
    background: transparent;
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: var(--radius);
    cursor: pointer;
    font: inherit;
    font-size: 12px;
  }
  .hist-use:hover { background: var(--accent-dim); }
  .stream {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
  }
  /* Keep the conversation in a centered, readable column — on a wide screen the
     full-width stream flung right-aligned (user) and left-aligned (assistant)
     bubbles to opposite edges, so the question was easy to miss. */
  .thread {
    max-width: 760px;
    margin: 0 auto;
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 10px;
    min-height: 100%;
  }
  .empty {
    color: var(--text-dim);
    margin: auto;
  }

  /* live "working" indicator — visible activity during long compiles/runs and
     until the server replies (or the connection drops -> an error item appears). */
  .working {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: var(--text-dim);
    padding: 2px 2px 4px;
  }
  .spin {
    width: 11px;
    height: 11px;
    border: 2px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  /* chat bubbles */
  .msg {
    max-width: 80%;
  }
  .msg.user {
    align-self: flex-end;
    text-align: right;
  }
  .who {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-dim);
  }
  .msg p {
    margin: 2px 0 0;
    padding: 8px 12px;
    border-radius: var(--radius);
    background: var(--surface-2);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .msg p.source {
    margin-top: 4px;
    padding: 4px 12px;
    background: transparent;
    font-size: 12px;
    color: var(--text-dim);
  }
  .msg p.source a {
    color: var(--accent, #3b82f6);
  }
  .msg.user p {
    background: var(--accent-dim);
  }

  /* status — small, inline, dim */
  .status {
    display: flex;
    align-items: baseline;
    gap: 7px;
    font-size: 11.5px;
    color: var(--text-dim);
    padding-left: 2px;
  }
  .status .icon {
    width: 1em;
    text-align: center;
  }
  .status.running .icon {
    color: var(--accent);
    animation: pulse 1.2s ease-in-out infinite;
  }
  @keyframes pulse {
    50% { opacity: 0.35; }
  }
  .status.done .icon { color: var(--ok); }
  .status.error .icon { color: var(--err); }
  .status.awaiting-approval .icon { color: var(--warn); }
  .status .detail {
    opacity: 0.8;
  }
  .status .elapsed {
    opacity: 0.6;
    font-variant-numeric: tabular-nums;
  }

  /* tags used — chips showing which category tag(s) answered the question */
  .tagsused {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    margin: 2px 0;
    font-size: 11.5px;
  }
  .tagsused .tlabel {
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-size: 10px;
  }
  .tagsused .chip {
    padding: 1px 8px;
    border-radius: 999px;
    background: var(--accent-dim, rgba(255, 122, 28, 0.12));
    color: var(--accent);
    border: 1px solid var(--accent);
    font-weight: 600;
  }

  /* debug — small, collapsible */
  .debug {
    font-size: 11.5px;
    color: var(--text-dim);
    border-left: 2px solid var(--border);
    padding-left: 8px;
  }
  .debug summary {
    cursor: pointer;
  }
  .debug pre {
    margin: 6px 0 0;
    padding: 8px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow-x: auto;
    font-size: 11px;
  }

  /* approval — regular font, inline block */
  .approval {
    border: 1px solid var(--warn);
    border-radius: var(--radius);
    background: var(--surface-2);
    padding: 10px 12px;
    font-size: 14px;
  }
  .atitle {
    margin: 0 0 8px;
    color: var(--warn);
  }
  .approval pre {
    margin: 0 0 8px;
    padding: 10px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    /* Cap tall programs at half the viewport and scroll (both axes) so a long
       generated program can't push the approve/reject buttons off-screen. */
    max-height: 50vh;
    overflow: auto;
    font-size: 12.5px;
  }
  .actions {
    display: flex;
    gap: 8px;
  }
  .actions button {
    padding: 6px 14px;
    border-radius: var(--radius);
    border: none;
    font-weight: 600;
  }
  .approve {
    background: var(--ok);
    color: var(--on-ok, #06120a);
  }
  .reject {
    background: transparent;
    color: var(--text-dim);
    border: 1px solid var(--border) !important;
  }
  .bump {
    background: transparent;
    color: var(--accent);
    border: 1px solid var(--accent) !important;
  }
  .bump:hover {
    background: var(--accent-dim);
  }
  .decision {
    margin: 0;
    font-size: 13px;
  }
  .decision.approved { color: var(--ok); }
  .decision.rejected { color: var(--err); }

  /* input */
  form {
    padding: 12px;
    /* keep the input clear of the iOS home-indicator / URL bar inset */
    padding-bottom: calc(12px + env(safe-area-inset-bottom));
    border-top: 1px solid var(--border);
  }
  .row {
    display: flex;
    gap: 8px;
    max-width: 760px;
    margin: 0 auto; /* match the centered conversation column */
  }
  input {
    flex: 1;
    padding: 9px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
  }
  input:focus {
    outline: none;
    border-color: var(--accent);
  }
  select {
    flex: 1;
    padding: 9px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font: inherit;
    cursor: pointer;
  }
  select:focus {
    outline: none;
    border-color: var(--accent);
  }
  form button {
    padding: 9px 16px;
    border-radius: var(--radius);
    border: none;
    background: var(--accent);
    color: #06101f;
    font-weight: 600;
  }
  form button:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
</style>
