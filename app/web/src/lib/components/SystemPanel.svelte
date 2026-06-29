<script module lang="ts">
  // System info from the server (/api/system): where the data + logs live, plus the
  // running version/model. Cached at MODULE scope (shared across tab switches — the
  // [[tab]] route destroys/recreates this component) so the tab shows last-known data
  // INSTANTLY instead of a perpetual "Loading…" while a question is being answered:
  // the app server can't serve the GET during a long synchronous query (one effective
  // worker — macOS SO_REUSEPORT doesn't load-balance, so MILLFOLIO_WORKERS doesn't
  // help). The paths/version don't change within a session, so stale-while-busy is fine.
  type Logs = { transcripts?: string; app?: string; server?: string };
  type Sys = {
    version?: string;
    model?: string;
    dataDir?: string;
    statsFile?: string;
    asksFile?: string;
    logs?: Logs;
  };
  let cachedSys: Sys | null = null;
</script>

<script lang="ts">
  import { onMount } from "svelte";

  let sys = $state<Sys | null>(cachedSys);
  let loaded = $state(cachedSys !== null); // have cached data → no "Loading…"
  let failed = $state(false);
  let copied = $state(""); // the path most recently copied (for the ✓ hint)

  // Same-origin in production; an explicit ?api=… wins; Vite dev (:5173) has no backend.
  function apiBase(): string {
    if (typeof location === "undefined") return "";
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    return "";
  }

  onMount(() => {
    // Refresh in the background; if the fetch stalls (server busy answering a
    // question), the cached data stays on screen instead of reverting to "Loading…".
    fetch(`${apiBase()}/api/system`)
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((d) => {
        sys = d as Sys;
        cachedSys = d as Sys;
        loaded = true;
      })
      .catch(() => {
        if (cachedSys === null) failed = true; // only "unavailable" with nothing cached
        loaded = true;
      });
  });

  async function copy(path: string) {
    try {
      await navigator.clipboard.writeText(path);
      copied = path;
      setTimeout(() => (copied = copied === path ? "" : copied), 1500);
    } catch {} // clipboard blocked — the path is still selectable text
  }

  // (label, path, hint) rows; only rendered when the path is present.
  const dataRows = $derived<[string, string | undefined, string][]>([
    ["Data directory", sys?.dataDir, "the index, extracted transactions, and the stores below"],
    ["Question history", sys?.asksFile, "every ask: question + generated program + answer"],
    ["Usage stats", sys?.statsFile, "per-question timing (the Stats tab)"],
  ]);
  const logRows = $derived<[string, string | undefined, string][]>([
    ["Per-ask transcripts", sys?.logs?.transcripts, "one file per question — the generated program AND its run output (start here when an answer looks wrong)"],
    ["App / server log", sys?.logs?.app, "the web app server (requests, codegen, run)"],
    ["Inference server log", sys?.logs?.server, "the local model engine"],
  ]);
</script>

<section class="system">
  <header>
    <h2>System</h2>
    {#if sys?.version || sys?.model}
      <p class="meta">
        {#if sys?.version}<span>version <strong>{sys.version}</strong></span>{/if}
        {#if sys?.model}<span>model <strong>{sys.model}</strong></span>{/if}
      </p>
    {/if}
  </header>

  {#if !loaded}
    <p class="muted">Loading…</p>
  {:else if failed}
    <p class="muted">System info unavailable — start millfolio with <code>mill start</code>.</p>
  {:else}
    <div class="group">
      <h3>Data</h3>
      {#each dataRows as [label, path, hint]}
        {#if path}
          <div class="row">
            <div class="rlabel">{label}<span class="hint">{hint}</span></div>
            <div class="rpath">
              <code>{path}</code>
              <button type="button" class="copy" onclick={() => copy(path)} title="Copy path">
                {copied === path ? "✓" : "Copy"}
              </button>
            </div>
          </div>
        {/if}
      {/each}
    </div>

    <div class="group">
      <h3>Logs</h3>
      {#each logRows as [label, path, hint]}
        {#if path}
          <div class="row">
            <div class="rlabel">{label}<span class="hint">{hint}</span></div>
            <div class="rpath">
              <code>{path}</code>
              <button type="button" class="copy" onclick={() => copy(path)} title="Copy path">
                {copied === path ? "✓" : "Copy"}
              </button>
            </div>
          </div>
        {/if}
      {/each}
      <p class="tip">
        Tail a log live in Terminal, e.g.
        <code>tail -f "{sys?.logs?.app ?? "~/Library/Application Support/Millfolio/Millfolio.log"}"</code>
      </p>
    </div>
  {/if}
</section>

<style>
  .system {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    max-width: 820px;
    margin: 0 auto;
    width: 100%;
  }
  header {
    display: flex;
    align-items: baseline;
    gap: 14px;
    flex-wrap: wrap;
    margin-bottom: 12px;
  }
  h2 {
    margin: 0;
    font-size: 16px;
  }
  .meta {
    margin: 0;
    display: flex;
    gap: 14px;
    font-size: 12px;
    color: var(--text-dim);
  }
  .meta strong {
    color: var(--text);
    font-variant-numeric: tabular-nums;
  }
  .group {
    margin-bottom: 20px;
  }
  h3 {
    margin: 0 0 8px;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-dim);
  }
  .row {
    padding: 8px 0;
    border-top: 1px solid var(--border);
  }
  .rlabel {
    display: flex;
    flex-direction: column;
    gap: 1px;
    font-size: 13px;
    margin-bottom: 4px;
  }
  .hint {
    font-size: 11.5px;
    color: var(--text-dim);
  }
  .rpath {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .rpath code {
    flex: 1;
    overflow-x: auto;
    white-space: nowrap;
    padding: 5px 8px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    font-size: 12px;
  }
  .copy {
    flex: none;
    padding: 5px 10px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
    font: inherit;
    font-size: 12px;
  }
  .copy:hover {
    color: var(--text);
    border-color: var(--accent);
  }
  .tip {
    margin: 10px 0 0;
    font-size: 12px;
    color: var(--text-dim);
  }
  .tip code {
    padding: 1px 5px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    font-size: 11.5px;
  }
  .muted {
    color: var(--text-dim);
  }
</style>
