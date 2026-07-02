<script lang="ts">
  import { onMount, onDestroy } from "svelte";

  // AI-tag backfill: an AI rule (`tag : question?`) costs one model call per
  // transaction, so its verdicts are backfilled once and cached in the `.tags`
  // column, then reused as a fast exact filter. This panel shows how far each AI
  // rule has been backfilled (a per-rule completion marker keyed on the insertion
  // generation), lets you drain the queue now, and pause the between-questions
  // worker. Backed by /api/backfill/{status,run,pause,resume}.
  // `standalone` = rendered as its own tab (System → Backfill) rather than
  // embedded in another panel: it then owns its padding/scroll and shows an empty
  // state when there are no AI rules yet.
  let { demo = false, standalone = false }: { demo?: boolean; standalone?: boolean } =
    $props();

  type PerTag = {
    tag: string;
    question: string;
    total: number;
    evaluated: number;
    pending: number;
    yes: number;
    ready: boolean;
  };
  type Status = {
    status: string;
    paused_until: number;
    priority?: string;
    perTag: PerTag[];
    pendingTotal: number;
  };

  let st = $state<Status | null>(null);
  let loaded = $state(false);
  let running = $state(false);
  let now = $state(Math.floor(Date.now() / 1000));

  function apiBase(): string {
    if (typeof location === "undefined") return "";
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    return "";
  }

  // A live ETA: measure how fast `pendingTotal` drops between samples (so it reflects
  // the CURRENT priority's throttle) → pending / rate. Recomputes as priority changes.
  let etaSeconds = $state<number | null>(null);
  let lastSample: { pending: number; t: number } | null = null;
  function noteProgress(pending: number) {
    const t = Date.now();
    if (lastSample && pending < lastSample.pending) {
      const dt = (t - lastSample.t) / 1000;
      if (dt > 0.5) {
        const rate = (lastSample.pending - pending) / dt; // rows/sec
        if (rate > 0) etaSeconds = Math.round(pending / rate);
      }
    }
    if (!lastSample || pending !== lastSample.pending) lastSample = { pending, t };
    if (pending <= 0) etaSeconds = 0;
  }

  async function loadStatus() {
    try {
      const r = await fetch(`${apiBase()}/api/backfill/status`);
      if (!r.ok) throw new Error();
      st = await r.json();
      if (st) noteProgress(st.pendingTotal);
      loaded = true;
    } catch {
      loaded = true; // stay quiet — the section just hides when there are no AI tags
    }
  }

  // Set the throttle. Reset the ETA sample so it re-measures at the new rate.
  async function setPriority(p: string) {
    lastSample = null;
    etaSeconds = null;
    const r = await fetch(`${apiBase()}/api/backfill/priority`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ priority: p }),
    });
    if (r.ok) st = (await r.json()).status as Status;
  }
  const fmtEta = (s: number) =>
    s >= 90 ? `${Math.round(s / 60)} min` : `${Math.max(1, Math.round(s))}s`;

  // "Backfill now" drains the whole queue by looping bounded slices, so each
  // request stays short and the bars advance live. Stops when nothing is pending,
  // a slice makes no progress (engine down), or the user leaves.
  let stop = false;
  async function runDrain() {
    if (running) return;
    running = true;
    stop = false;
    try {
      for (let i = 0; i < 1000; i++) {
        if (stop) break;
        const r = await fetch(`${apiBase()}/api/backfill/run`, { method: "POST" });
        if (!r.ok) break;
        const body = await r.json();
        st = body.status as Status;
        if (st) noteProgress(st.pendingTotal);
        if (!st || st.pendingTotal <= 0) break;
        if ((body.changed ?? 0) === 0 && st.status !== "paused") break; // no progress → stop
        if (st.status === "paused") break;
      }
    } finally {
      running = false;
    }
  }

  async function pause(seconds: number) {
    const r = await fetch(`${apiBase()}/api/backfill/pause`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ seconds }),
    });
    if (r.ok) st = (await r.json()).status as Status;
  }
  async function resume() {
    stop = false;
    const r = await fetch(`${apiBase()}/api/backfill/resume`, { method: "POST" });
    if (r.ok) st = (await r.json()).status as Status;
  }

  const pct = (t: PerTag) => (t.total === 0 ? 100 : Math.round((t.evaluated / t.total) * 100));
  const pausedFor = $derived(st && st.paused_until > now ? st.paused_until - now : 0);
  const fmtDur = (s: number) => (s >= 60 ? `${Math.round(s / 60)} min` : `${s}s`);

  let poll: ReturnType<typeof setInterval> | undefined;
  let tick: ReturnType<typeof setInterval> | undefined;
  onMount(() => {
    loadStatus();
    poll = setInterval(loadStatus, 4000);
    tick = setInterval(() => (now = Math.floor(Date.now() / 1000)), 1000);
  });
  onDestroy(() => {
    stop = true;
    if (poll) clearInterval(poll);
    if (tick) clearInterval(tick);
  });
</script>

<div class="wrap" class:standalone>
{#if loaded && st && st.perTag.length === 0 && standalone}
  <div class="empty">
    <h3>AI-tag backfill</h3>
    <p>
      No AI category rules yet. An AI rule (<code>tag : question?</code>) is answered
      by the on-device model and cached, then reused as a fast filter. Add one in the
      <a href="/tags">Tags</a> tab, and its backfill progress will appear here.
    </p>
  </div>
{/if}
{#if loaded && st && st.perTag.length > 0}
  <div class="mat">
    <div class="mhead">
      <h3>AI-tag backfill</h3>
      <span class="sub">
        {#if st.pendingTotal > 0}
          {st.pendingTotal} transaction-verdict{st.pendingTotal === 1 ? "" : "s"} to compute
          {#if etaSeconds && etaSeconds > 0} · ~{fmtEta(etaSeconds)} left{/if}
        {:else}
          all AI tags backfilled
        {/if}
      </span>
    </div>

    {#if !demo}
      <div class="prio">
        <span class="plabel">Priority</span>
        {#each ["high", "medium", "low"] as p}
          <button
            type="button"
            class="pbtn"
            class:active={(st.priority ?? "medium") === p}
            onclick={() => setPriority(p)}
          >{p}</button>
        {/each}
        <span class="phint">
          Low leaves the GPU mostly free (slower); high is fastest but uses most of it.
        </span>
      </div>
    {/if}

    <div class="bars">
      {#each st.perTag as t}
        <div class="bar">
          <div class="btop">
            <span class="bname">{t.tag}</span>
            {#if t.ready}
              <span class="badge ok">ready</span>
            {:else}
              <span class="badge pend">pending</span>
            {/if}
            <span class="frac">{t.evaluated}/{t.total} · {pct(t)}%</span>
            <span class="yes">{t.yes} match{t.yes === 1 ? "" : "es"}</span>
          </div>
          <div class="track"><div class="fill" style="width:{pct(t)}%"></div></div>
        </div>
      {/each}
    </div>

    {#if !demo}
      <div class="controls">
        {#if pausedFor > 0}
          <span class="paused">paused for {fmtDur(pausedFor)}</span>
          <button type="button" class="btn" onclick={resume}>Resume</button>
        {:else}
          <button
            type="button"
            class="btn primary"
            onclick={runDrain}
            disabled={running || st.pendingTotal === 0}
          >
            {running ? "Backfilling…" : "Backfill now"}
          </button>
          <button type="button" class="btn" onclick={() => pause(3600)}>Pause 1h</button>
        {/if}
        <span class="hint">
          Runs the on-device model over the pending transactions — cached once, then
          reused as a fast exact filter. Needs <code>mill start</code> up.
        </span>
      </div>
    {/if}
  </div>
{/if}
</div>

<style>
  .wrap.standalone {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    max-width: 820px;
    margin: 0 auto;
    width: 100%;
  }
  .empty {
    color: var(--text-dim);
  }
  .empty h3 {
    margin: 0 0 8px;
    font-size: 14px;
    color: var(--text);
  }
  .empty p {
    margin: 0;
    line-height: 1.55;
    font-size: 13px;
  }
  .empty a {
    color: var(--accent);
  }
  .mat {
    background: var(--surface-2);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 14px 16px;
    margin-bottom: 18px;
  }
  .mhead {
    display: flex;
    align-items: baseline;
    gap: 10px;
    margin-bottom: 10px;
  }
  .mhead h3 {
    margin: 0;
    font-size: 14px;
  }
  .sub {
    font-size: 12px;
    color: var(--text-dim);
  }
  .bars {
    display: flex;
    flex-direction: column;
    gap: 9px;
  }
  .btop {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    margin-bottom: 3px;
  }
  .bname {
    font-weight: 600;
  }
  .badge {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    border-radius: 999px;
    padding: 0 6px;
  }
  .badge.ok {
    color: var(--ok);
    border: 1px solid var(--ok);
  }
  .badge.pend {
    color: var(--warn);
    border: 1px solid var(--warn);
  }
  .frac {
    color: var(--text-dim);
  }
  .yes {
    margin-left: auto;
    color: var(--text-dim);
  }
  .track {
    height: 6px;
    background: var(--bg);
    border-radius: 999px;
    overflow: hidden;
  }
  .fill {
    height: 100%;
    background: var(--accent);
    border-radius: 999px;
    transition: width 0.3s ease;
  }
  .controls {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-top: 12px;
    flex-wrap: wrap;
  }
  .prio {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 12px;
    flex-wrap: wrap;
  }
  .plabel {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-dim);
    margin-right: 2px;
  }
  .pbtn {
    padding: 3px 12px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
    font: inherit;
    font-size: 12px;
    text-transform: capitalize;
  }
  .pbtn:hover {
    border-color: var(--accent);
  }
  .pbtn.active {
    background: var(--accent);
    border-color: var(--accent);
    color: #06101f;
    font-weight: 600;
  }
  .phint {
    flex-basis: 100%;
    font-size: 11px;
    color: var(--text-dim);
  }
  .paused {
    font-size: 12px;
    color: var(--warn);
  }
  .hint {
    font-size: 11px;
    color: var(--text-dim);
  }
  .btn {
    padding: 6px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text);
    cursor: pointer;
    font: inherit;
    font-size: 13px;
  }
  .btn:hover {
    border-color: var(--accent);
  }
  .btn.primary {
    background: var(--accent);
    border-color: var(--accent);
    color: #fff;
    font-weight: 600;
  }
  .btn:disabled {
    opacity: 0.55;
    cursor: default;
  }
  code {
    font-family: var(--mono);
    font-size: 0.92em;
  }
</style>
