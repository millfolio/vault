<script lang="ts">
  // Operations — a read-only, durable history of the vault's background runs
  // (index / re-index / AI-tag backfill), from the local server's
  // GET /api/operations (backed by operations.jsonl). Newest-first. The currently
  // running index job (if any) is pinned live at the top via /api/index/status.
  import { onMount } from "svelte";

  let { demo = false }: { demo?: boolean } = $props();

  // Same-origin resolution as VaultPanel: an explicit ?api= wins; Vite dev (:5173)
  // has no backend → sample data; every other origin is served by millfolio-server.
  function apiBase(): string | null {
    if (typeof location === "undefined") return null;
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    if (location.port === "5173") return null;
    return "";
  }

  interface Operation {
    type: "index" | "reindex" | "backfill" | string;
    started: number; // epoch seconds
    finished: number; // epoch seconds
    status: "done" | "error" | string;
    detail: string;
    files?: number;
    txns?: number;
    tagged?: number;
  }
  interface IndexStatus {
    state: "idle" | "indexing" | "done" | "error";
    detail: string;
    current?: number; // present only during the per-file embedding phase ([n/M])
    total?: number;
  }

  const MOCK_OPS: Operation[] = [
    { type: "backfill", started: 1783200000, finished: 1783200019, status: "done", detail: "AI-tag backfill complete", tagged: 42 },
    { type: "reindex", started: 1783100000, finished: 1783100126, status: "done", detail: "Indexed 128 chunks across 6 files", files: 6, txns: 444 },
    { type: "index", started: 1783000000, finished: 1782999940, status: "error", detail: "embedding engine not reachable (503)" },
  ];

  let ops = $state<Operation[] | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let mock = $state(false);
  let idxStatus = $state<IndexStatus | null>(null);

  function label(t: string): string {
    if (t === "index") return "Index";
    if (t === "reindex") return "Re-index";
    if (t === "backfill") return "Backfill";
    return t;
  }

  // finished - started, as a compact "3.2s" / "1m 04s" (guards against a clock
  // skew that would make finished < started → shows "—").
  function fmtDur(o: Operation): string {
    const s = o.finished - o.started;
    if (!Number.isFinite(s) || s < 0) return "—";
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    const rem = s % 60;
    return `${m}m ${String(rem).padStart(2, "0")}s`;
  }

  function fmtWhen(epoch: number): string {
    if (!epoch || Number.isNaN(epoch)) return "—";
    return new Date(epoch * 1000).toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
  }

  async function load() {
    loading = true;
    error = null;
    const base = apiBase();
    if (base === null) {
      ops = MOCK_OPS;
      mock = true;
      loading = false;
      return;
    }
    // The history read can hang while an index holds the config dir busy; cap it at
    // 8s so a stuck request degrades to a small "couldn't load history" line rather
    // than an infinite spinner (the running-index row renders independently below).
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 8000);
    try {
      const res = await fetch(`${base}/api/operations`, {
        headers: { accept: "application/json" },
        signal: ctrl.signal,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      ops = ((await res.json()).operations ?? []) as Operation[];
      mock = false;
    } catch (e) {
      error = ctrl.signal.aborted
        ? "timed out"
        : e instanceof Error
          ? e.message
          : String(e);
    } finally {
      clearTimeout(timer);
      loading = false;
    }
  }

  // Poll the current index job so a running index shows live at the top, and so the
  // list refreshes the moment a run settles (the server records it on the same poll).
  async function pollStatus() {
    const base = apiBase();
    if (base === null) return;
    let prev = idxStatus?.state;
    try {
      const d = (await fetch(`${base}/api/index/status`).then((r) => (r.ok ? r.json() : null))) as IndexStatus | null;
      if (d) {
        idxStatus = d;
        // A transition OUT of "indexing" means a run just settled → a new record
        // exists; reload the list to pick it up.
        if (prev === "indexing" && d.state !== "indexing") await load();
      }
    } catch {
      /* transient — keep polling */
    }
  }

  onMount(() => {
    load();
    if (!demo && apiBase() !== null) {
      pollStatus();
      const t = setInterval(pollStatus, 2000);
      return () => clearInterval(t);
    }
  });

  const running = $derived(idxStatus?.state === "indexing");
</script>

<section class="ops">
  {#if mock}
    <p class="banner">Sample data — open this from <code>mill start</code> (:10000) to see your real operations.</p>
  {/if}

  <ul class="oplist">
    <!-- The live running-index row renders IMMEDIATELY from the /api/index/status
         poll — never gated behind the (possibly slow) /api/operations history fetch,
         so an active index shows "n of M" right away instead of "Loading…". -->
    {#if running}
      <li class="op live">
        <div class="line1">
          <span class="type">Index</span>
          <span class="badge running"><span class="spin" aria-hidden="true"></span>running</span>
          <span class="when">now</span>
        </div>
        {#if idxStatus?.total && idxStatus.total > 0}
          <div class="progress">
            <div class="pbar" aria-hidden="true">
              <div class="pfill" style={`width:${Math.min(100, ((idxStatus.current ?? 0) / idxStatus.total) * 100)}%`}></div>
            </div>
            <span class="pcount">{idxStatus.current ?? 0} of {idxStatus.total} files</span>
          </div>
        {:else if idxStatus?.detail}
          <p class="detail">{idxStatus.detail}</p>
        {/if}
      </li>
    {/if}

    <!-- History states — independent of the running row. On a slow/hung fetch this
         shows a spinner then degrades to a small line, never an infinite spinner. -->
    {#if loading && ops === null}
      <li class="loadingrow"><p class="muted">Loading history…</p></li>
    {:else if error}
      <li class="loadingrow"><p class="muted hint">Couldn't load history: {error}</p></li>
    {:else if ops && ops.length > 0}
      {#each ops as o, i (o.started + "-" + o.type + "-" + i)}
        <li class="op">
          <div class="line1">
            <span class="type">{label(o.type)}</span>
            {#if o.status === "done"}
              <span class="badge ok">✓ done</span>
            {:else if o.status === "error"}
              <span class="badge err">✗ error</span>
            {:else}
              <span class="badge">{o.status}</span>
            {/if}
            <span class="dur">{fmtDur(o)}</span>
            <span class="counts">
              {#if typeof o.files === "number"}<span class="ct">{o.files} file{o.files === 1 ? "" : "s"}</span>{/if}
              {#if typeof o.txns === "number"}<span class="ct">{o.txns.toLocaleString()} txns</span>{/if}
              {#if typeof o.tagged === "number"}<span class="ct">{o.tagged.toLocaleString()} tagged</span>{/if}
            </span>
            <span class="when">{fmtWhen(o.started)}</span>
          </div>
          {#if o.detail}
            <p class="detail">{o.detail}</p>
          {/if}
        </li>
      {/each}
    {:else if !running}
      <li class="empty">
        <p class="muted">No operations yet.</p>
        <p class="muted hint">Index a folder or run an AI-tag backfill and its runs will show up here.</p>
      </li>
    {/if}
  </ul>
</section>

<style>
  .ops {
    padding: 0;
  }
  .oplist {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .op {
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--bg);
    padding: 10px 14px;
  }
  .op.live {
    border-color: var(--accent);
  }
  .line1 {
    display: flex;
    align-items: baseline;
    flex-wrap: wrap;
    gap: 10px;
  }
  .type {
    font-weight: 600;
    font-size: 13px;
    color: var(--text);
  }
  .badge {
    font-size: 11.5px;
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }
  .badge.ok {
    color: var(--ok);
  }
  .badge.err {
    color: var(--err);
  }
  .badge.running {
    color: var(--accent);
  }
  .dur {
    font-size: 12px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .counts {
    display: inline-flex;
    gap: 10px;
    flex-wrap: wrap;
  }
  .counts .ct {
    font-size: 11.5px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .when {
    margin-left: auto;
    font-size: 11.5px;
    color: var(--text-dim);
  }
  .detail {
    margin: 6px 0 0;
    font-size: 12px;
    color: var(--text-dim);
    word-break: break-word;
  }
  .progress {
    margin: 8px 0 0;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .pbar {
    flex: 1 1 auto;
    height: 5px;
    border-radius: 3px;
    background: var(--surface-2);
    overflow: hidden;
  }
  .pfill {
    height: 100%;
    background: var(--accent);
    border-radius: 3px;
    transition: width 0.3s ease;
  }
  .pcount {
    flex: none;
    font-size: 11.5px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .empty {
    padding: 20px 0;
  }
  .loadingrow {
    padding: 12px 2px;
  }
  .muted {
    color: var(--text-dim);
  }
  .hint {
    margin-top: 6px;
    font-size: 12px;
  }
  .banner {
    margin: 0 0 14px;
    padding: 8px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--surface-2);
    font-size: 12.5px;
    color: var(--text-dim);
  }
  .banner code {
    font-family: var(--mono);
  }
  .spin {
    flex: none;
    width: 11px;
    height: 11px;
    border: 2px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    display: inline-block;
    animation: opspin 0.8s linear infinite;
  }
  @keyframes opspin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
