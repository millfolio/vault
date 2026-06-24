<script lang="ts">
  import { onDestroy } from "svelte";
  import type { StepState } from "$lib/protocol";

  // One inline timeline: chat bubbles (user/assistant), plus the workflow events
  // rendered in place — status/debug small, approval at regular font. Mirrors the
  // ChatItem union in routes/+page.svelte.
  interface Item {
    kind: "user" | "assistant" | "status" | "debug" | "approval";
    id: string;
    text?: string;
    stepId?: string;
    label?: string;
    state?: StepState;
    detail?: string;
    title?: string;
    body?: string;
    language?: string;
    resolved?: "approved" | "rejected";
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

  // The curated demo questions — the ONLY ones the replay cache can answer. Keep in
  // sync with scripts/prime-cache.sh in the demo repo (those captures ARE the demo).
  const SUGGESTED = [
    "how many transactions do I have",
    "what is my biggest transaction",
    "what is the total of my transactions",
    "what kinds of files are in my vault",
    "how much did I spend",
  ];

  let draft = $state("");
  let picked = $state("");
  let stream = $state<HTMLDivElement>();

  // Demo auto-approve: the public demo shouldn't park on the "Approve" gate (the
  // single-threaded server would wedge), so in demo mode an unresolved approval gets
  // a 15s countdown and then auto-approves. "+1 min" extends it for a closer look.
  // (The real product keeps manual approval — gated on `demo`.)
  const AUTO_APPROVE_SECS = 15;
  let remaining = $state(0); // seconds left on the current auto-approve countdown
  let pendingId = $state<string | null>(null); // approval id currently being timed
  let ticker: ReturnType<typeof setInterval> | undefined;
  function stopTimer() {
    if (ticker !== undefined) clearInterval(ticker);
    ticker = undefined;
    pendingId = null;
  }
  function bumpTimer() {
    remaining += 60;
  }
  onDestroy(stopTimer);

  // Track the latest unresolved approval and (re)start the countdown for it.
  $effect(() => {
    const pending = demo ? [...items].reverse().find((x) => x.kind === "approval" && !x.resolved) : undefined;
    if (!pending) {
      if (pendingId !== null) stopTimer();
      return;
    }
    if (pending.id === pendingId) return; // already counting down for this one
    stopTimer();
    pendingId = pending.id;
    remaining = AUTO_APPROVE_SECS;
    ticker = setInterval(() => {
      remaining -= 1;
      if (remaining <= 0) {
        const id = pendingId;
        const step = items.find((x) => x.id === id)?.stepId ?? "";
        stopTimer();
        if (id) onapprove(id, step);
      }
    }, 1000);
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

  function submit(e: SubmitEvent) {
    e.preventDefault();
    const t = draft.trim();
    if (!t || busy) return;
    onsend(t);
    draft = "";
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
        </div>
      {:else if it.kind === "status"}
        <div class="status {it.state}">
          <span class="icon" aria-hidden="true">{icon[it.state ?? "pending"]}</span>
          <span class="label">{it.label}</span>
          {#if it.detail}<span class="detail">— {it.detail}</span>{/if}
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
                {#if demo && it.id === pendingId}Approve ({remaining}s){:else}Approve{/if}
              </button>
              {#if demo && it.id === pendingId}
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
          <option value="" disabled>Pick a question…</option>
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
        <input type="text" placeholder="My question is…" bind:value={draft} disabled={busy} />
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
  }
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
    overflow-x: auto;
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
