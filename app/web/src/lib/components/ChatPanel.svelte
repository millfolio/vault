<script lang="ts">
  import { onMount } from "svelte";
  import type { StepState } from "$lib/protocol";

  // One inline timeline: chat bubbles (user/assistant), plus the workflow events
  // rendered in place — status/debug small, approval at regular font. Mirrors the
  // ChatItem union in routes/+page.svelte.
  interface Item {
    kind: "user" | "assistant" | "status" | "debug" | "approval" | "tags" | "tag-proposal";
    id: string;
    text?: string;
    tags?: string;         // tags: comma-joined category tags the program filtered on
    name?: string;         // tag-proposal: suggested tag name
    keywords?: string;     // tag-proposal: suggested keywords (comma-joined)
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
    // Focus FIRST — focusing fires the input's onfocus (which would re-open the
    // panel), so close it AFTER so "Ask again" actually dismisses the list.
    inputEl?.focus();
    showHistory = false;
  }
  // Remove a question from history — from the local list + cache AND (best-effort)
  // the durable backend store, so it doesn't reappear on the next load.
  async function deleteRecent(q: string) {
    recent = recent.filter((r) => r.q !== q);
    try {
      localStorage.setItem(RECENT_KEY, JSON.stringify(recent.map((r) => r.q)));
    } catch {}
    if (recent.length === 0) showHistory = false;
    if (demo) return;
    try {
      await fetch(`${apiBase()}/api/history/delete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ q }),
      });
    } catch {} // best-effort — the local list is already updated
  }

  // Auto-approve countdown: an unresolved approval gets a 15s countdown then
  // auto-approves, with "+1 min" to extend for a closer look. Used in BOTH the real
  // product and the public demo (the demo also can't park on the gate — its
  // single-threaded server would wedge). Immediate Approve and Reject stay available.
  const AUTO_APPROVE_SECS = 15;
  let remaining = $state(0); // seconds left on the current auto-approve countdown
  // The id of the approval currently awaiting a decision (null if none). $derived so it
  // recomputes reactively for EVERY question, not just the first.
  const pendingApprovalId = $derived<string | null>(
    [...items].reverse().find((x) => x.kind === "approval" && !x.resolved)?.id ?? null,
  );
  function bumpTimer() {
    remaining += 60;
  }

  // Accept a model-proposed reusable tag: append `name = keywords` to the category
  // rules (read-modify-write /api/categories) so it becomes a permanent fast tag —
  // the SAME store the Tags tab edits. Disabled in the read-only demo.
  function apiBase(): string {
    if (typeof location === "undefined") return "";
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    return "";
  }
  let proposalState = $state<Record<string, "saving" | "added" | "error">>({});
  // Per-proposal edit state — the model's suggested keywords are just a starting
  // point (often not your actual merchants). The user can keep them as-is, edit them,
  // or switch to an AI rule (the model classifies — no exact keyword list needed).
  type PEdit = { kw: string; isMl: boolean; ml: string };
  let proposalEdits = $state<Record<string, PEdit>>({});
  let customizing = $state<Record<string, boolean>>({});
  function startCustomize(it: Item) {
    if (!proposalEdits[it.id]) {
      proposalEdits = {
        ...proposalEdits,
        [it.id]: { kw: it.keywords ?? "", isMl: false, ml: `is this a ${it.name}?` },
      };
    }
    customizing = { ...customizing, [it.id]: true };
  }
  function cleanName(s: string): string {
    return s.replace(/[,=:()\t\n]/g, "").trim();
  }
  async function acceptProposal(it: Item) {
    if (demo) return;
    const id = it.id;
    const name = cleanName(it.name ?? "");
    const e = proposalEdits[id];
    let rule = "";
    if (e?.isMl) {
      const q = (e.ml ?? "").trim();
      if (!name || !q) return;
      rule = `${name} : ${q}`;
    } else {
      const kw = (e?.kw ?? it.keywords ?? "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
        .join(", ");
      if (!name || !kw) return;
      rule = `${name} = ${kw}`;
    }
    proposalState = { ...proposalState, [id]: "saving" };
    try {
      const base = apiBase();
      const cur = await (await fetch(`${base}/api/categories`)).json();
      let text: string = cur.text ?? "";
      if (text.length && !text.endsWith("\n")) text += "\n";
      text += `${rule}\n`;
      const r = await fetch(`${base}/api/categories`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
      });
      const d = await r.json();
      if (!r.ok || !d.ok) throw new Error();
      proposalState = { ...proposalState, [id]: "added" };
    } catch {
      proposalState = { ...proposalState, [id]: "error" };
    }
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
        {#each recent as r (r.q)}
          <li class="hist-li">
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
            <button
              type="button"
              class="hist-del"
              title="Remove from history"
              aria-label="Remove this question from history"
              onclick={(e) => { e.stopPropagation(); deleteRecent(r.q); }}
            >×</button>
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
          {#each (it.tags ?? "").split(",") as t}<a class="chip" href="/tags" title="See this tag's rule in the Tags tab">{t}</a>{/each}
        </div>
      {:else if it.kind === "tag-proposal"}
        <div class="proposal" title="Save this as a category tag so the next such question is a fast, exact filter — no model call">
          <div class="ptext">
            <span class="plabel">💡 Make <strong>{it.name}</strong> a reusable tag?</span>
            {#if !customizing[it.id]}<span class="pkw">{it.keywords}</span>{/if}
          </div>
          {#if !demo}
            {#if proposalState[it.id] === "added"}
              <span class="padded">✓ Saved to your tags</span>
            {:else if customizing[it.id]}
              <div class="pcustom">
                <label class="pmltoggle" title="The model decides per transaction — no keyword list needed (slower, evaluated at index time)">
                  <input type="checkbox" bind:checked={proposalEdits[it.id].isMl} /> AI rule (model decides — no keyword list)
                </label>
                {#if proposalEdits[it.id].isMl}
                  <input class="pinput" placeholder="yes/no question — e.g. is this a gym or fitness studio?" bind:value={proposalEdits[it.id].ml} spellcheck="false" />
                {:else}
                  <input class="pinput" placeholder="keywords, comma, separated — your actual merchants" bind:value={proposalEdits[it.id].kw} spellcheck="false" />
                {/if}
                <div class="pactions">
                  <button class="padd" disabled={proposalState[it.id] === "saving"} onclick={() => acceptProposal(it)}>
                    {proposalState[it.id] === "saving" ? "Adding…" : "Add tag"}
                  </button>
                  <button class="pbtn" onclick={() => (customizing = { ...customizing, [it.id]: false })}>Cancel</button>
                  {#if proposalState[it.id] === "error"}<span class="perr">Couldn't save</span>{/if}
                </div>
              </div>
            {:else}
              <div class="pactions">
                <button class="padd" disabled={proposalState[it.id] === "saving"} onclick={() => acceptProposal(it)}>
                  {proposalState[it.id] === "saving" ? "Adding…" : "Add as suggested"}
                </button>
                <button class="pbtn" onclick={() => startCustomize(it)}>Customize…</button>
                {#if proposalState[it.id] === "error"}<span class="perr">Couldn't save</span>{/if}
              </div>
            {/if}
          {/if}
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
                {#if it.id === pendingApprovalId}Approve ({remaining}s){:else}Approve{/if}
              </button>
              {#if it.id === pendingApprovalId}
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
  .hist-li {
    position: relative;
  }
  /* delete affordance — revealed on row hover, top-right */
  .hist-del {
    position: absolute;
    top: 4px;
    right: 4px;
    width: 22px;
    height: 22px;
    display: flex;
    align-items: center;
    justify-content: center;
    border: none;
    background: var(--surface-2);
    color: var(--text-dim);
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 15px;
    line-height: 1;
    opacity: 0;
    transition: opacity 0.1s ease, color 0.1s ease;
  }
  .hist-li:hover .hist-del,
  .hist-del:focus-visible {
    opacity: 1;
  }
  /* Touch devices can't hover — always show the delete button so it's tappable. */
  @media (hover: none) {
    .hist-del {
      opacity: 1;
    }
  }
  .hist-del:hover {
    color: var(--err, #f85149);
  }
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
    text-decoration: none;
    cursor: pointer;
  }
  .tagsused a.chip:hover {
    background: var(--accent);
    color: #06101f;
  }

  /* tag-proposal — a dashed callout offering to save a model-suggested tag */
  .proposal {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
    margin: 4px 0;
    padding: 8px 12px;
    border: 1px dashed var(--accent);
    border-radius: var(--radius);
    background: var(--accent-dim, rgba(255, 122, 28, 0.08));
  }
  .proposal .ptext {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .proposal .plabel {
    font-size: 12.5px;
  }
  .proposal .plabel strong {
    color: var(--accent);
  }
  .proposal .pkw {
    font-size: 11.5px;
    color: var(--text-dim);
    overflow-wrap: anywhere;
  }
  .proposal .pactions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: none;
  }
  .proposal .padd {
    padding: 5px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--accent);
    background: var(--accent);
    color: #06101f;
    font: inherit;
    font-size: 12.5px;
    font-weight: 600;
    cursor: pointer;
  }
  .proposal .padd:disabled {
    opacity: 0.55;
    cursor: default;
  }
  .proposal .padded {
    font-size: 12px;
    color: var(--accent);
    font-weight: 600;
  }
  .proposal .perr {
    font-size: 11.5px;
    color: var(--err, #f85149);
  }
  .proposal .pbtn {
    padding: 5px 10px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    cursor: pointer;
  }
  .proposal .pbtn:hover {
    border-color: var(--accent);
  }
  .proposal .pcustom {
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 7px;
    margin-top: 4px;
  }
  .proposal .pmltoggle {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: var(--text-dim);
  }
  .proposal .pinput {
    width: 100%;
    box-sizing: border-box;
    font: inherit;
    font-size: 12.5px;
    color: var(--text);
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 6px 9px;
  }
  .proposal .pinput:focus {
    outline: none;
    border-color: var(--accent);
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
