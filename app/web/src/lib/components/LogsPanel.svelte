<script lang="ts">
  import { onMount } from "svelte";
  import DisclaimerContent from "./DisclaimerContent.svelte";

  // System info from the server (/api/system): where the data + logs live, plus the
  // running version/model. The point of this tab is discoverability — when an answer
  // looks wrong, the per-ask transcript holds the generated program AND its run
  // output, which is the fastest way to see what the model actually did.
  type Logs = { transcripts?: string; app?: string; server?: string };
  type Sys = {
    dataDir?: string;
    statsFile?: string;
    asksFile?: string;
    categoriesFile?: string;
    logs?: Logs;
  };

  // `demo` masks absolute home paths (the public demo shouldn't leak the server's
  // real home dir / username — show $HOME instead).
  let { demo = false }: { demo?: boolean } = $props();

  let sys = $state<Sys | null>(null);
  let loaded = $state(false);
  let failed = $state(false);
  let copied = $state(""); // the path most recently copied (for the ✓ hint)

  // Same-origin in production; an explicit ?api=… wins; Vite dev (:5173) has no backend.
  function apiBase(): string {
    if (typeof location === "undefined") return "";
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    return "";
  }

  // In demo mode, replace a leading home dir (/Users/<u> or /home/<u>) with $HOME so
  // the public demo never shows the server account's real path. No-op otherwise.
  function shown(path: string): string {
    if (!demo) return path;
    return path.replace(/^\/Users\/[^/]+/, "$HOME").replace(/^\/home\/[^/]+/, "$HOME");
  }

  onMount(() => {
    fetch(`${apiBase()}/api/system`)
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((d) => {
        sys = d as Sys;
        loaded = true;
      })
      .catch(() => {
        failed = true;
        loaded = true;
      });
  });

  // Copy the displayed (masked) path — never the raw home path in demo mode.
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
    ["Category rules", sys?.categoriesFile, "your editable tag keywords (phone, travel, …) — add your own, then re-index to retag"],
  ]);
  const logRows = $derived<[string, string | undefined, string][]>([
    ["Per-ask transcripts", sys?.logs?.transcripts, "one file per question — the generated program AND its run output (start here when an answer looks wrong)"],
    ["App / server log", sys?.logs?.app, "the web app server (requests, codegen, run)"],
    ["Inference server log", sys?.logs?.server, "the local model engine"],
  ]);
</script>

{#snippet pathRow(label: string, path: string, hint: string)}
  <div class="row">
    <div class="rlabel">{label}<span class="hint">{hint}</span></div>
    <div class="rpath">
      <code>{shown(path)}</code>
      <button
        type="button"
        class="copy"
        class:copied={copied === shown(path)}
        onclick={() => copy(shown(path))}
        aria-label={copied === shown(path) ? "Copied" : "Copy path"}
        title={copied === shown(path) ? "Copied" : "Copy path"}
      >
        {#if copied === shown(path)}
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M20 6 9 17l-5-5" />
          </svg>
        {:else}
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <rect x="9" y="9" width="13" height="13" rx="2" />
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
          </svg>
        {/if}
      </button>
    </div>
  </div>
{/snippet}

<section class="system">
  {#if !loaded}
    <p class="muted">Loading…</p>
  {:else if failed}
    <p class="muted">System info unavailable — start millfolio with <code>mill start</code>.</p>
  {:else}
    <div class="group">
      <h3>Data</h3>
      {#each dataRows as [label, path, hint]}
        {#if path}{@render pathRow(label, path, hint)}{/if}
      {/each}
    </div>

    <div class="group">
      <h3>Logs</h3>
      {#each logRows as [label, path, hint]}
        {#if path}{@render pathRow(label, path, hint)}{/if}
      {/each}
      <p class="tip">
        Tail a log live in Terminal, e.g.
        <code>tail -f "{shown(sys?.logs?.app ?? "~/Library/Application Support/Millfolio/Millfolio.log")}"</code>
      </p>
    </div>
  {/if}

  <!-- Always-available legal/liability notice (the same text as the first-run
       notice), so "what/where/legal" info all lives together on this tab. -->
  <div class="group legal">
    <h3>Legal</h3>
    <details class="disc-details">
      <summary>Disclaimer</summary>
      <div class="disc-inline">
        <DisclaimerContent heading="h3" />
      </div>
    </details>
    <p class="tip">
      Full text online:
      <a href="https://millfolio.app/disclaimer" target="_blank" rel="noopener">millfolio.app/disclaimer ↗</a>
    </p>
  </div>
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
  /* Icon-only copy affordance: hidden until the row is hovered/focused (or just
     copied, so the ✓ feedback is visible), copies on click. */
  .copy {
    flex: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border-radius: var(--radius);
    border: 1px solid transparent;
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.12s ease, color 0.12s ease, border-color 0.12s ease;
  }
  .rpath:hover .copy,
  .copy:focus-visible,
  .copy.copied {
    opacity: 1;
  }
  /* Touch devices can't hover — always show the copy button so it's tappable. */
  @media (hover: none) {
    .copy {
      opacity: 1;
    }
  }
  .copy:hover {
    color: var(--text);
    border-color: var(--accent);
  }
  .copy.copied {
    color: var(--ok, #3fb950);
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
  .disc-details > summary {
    cursor: pointer;
    font-size: 13px;
    color: var(--accent);
    padding: 4px 0;
    list-style: revert;
  }
  .disc-details > summary:hover {
    text-decoration: underline;
  }
  .disc-inline {
    padding: 8px 0 4px;
    max-width: 70ch;
  }
</style>
