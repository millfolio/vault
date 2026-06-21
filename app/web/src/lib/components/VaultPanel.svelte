<script lang="ts">
  // Vault view — the indexable files in your vault dir + LanceDB index stats,
  // from the local server's GET /api/vault. Read-only; refreshable.
  import { onMount } from "svelte";

  interface VaultFile {
    alias: string;
    name: string;
    kind: string;
    sizeBytes: number;
    chunks: number;
  }
  interface VaultInfo {
    vaultDir: string;
    configDir: string;
    indexed: boolean;
    embeddingDim: number;
    fileCount: number;
    indexedFileCount: number;
    chunkCount: number;
    dbSizeBytes: number;
    files: VaultFile[];
  }

  // Same-origin in production (served by millfolio-server on :10000); an explicit
  // ?api=http://host:10000 wins; otherwise (e.g. `npm run dev` on :5173) there's
  // no backend, so we show sample data.
  function apiBase(): string | null {
    if (typeof location === "undefined") return null;
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    if (location.port === "10000") return "";
    return null;
  }

  const MOCK: VaultInfo = {
    vaultDir: "~/.config/millfolio/vault",
    configDir: "~/.config/millfolio",
    indexed: true,
    embeddingDim: 1024,
    fileCount: 3,
    indexedFileCount: 3,
    chunkCount: 128,
    dbSizeBytes: 2_310_144,
    files: [
      { alias: "file_0", name: "accounts.csv", kind: "csv", sizeBytes: 20_480, chunks: 18 },
      { alias: "file_1", name: "notes.md", kind: "md", sizeBytes: 7_900, chunks: 12 },
      { alias: "file_2", name: "statement.pdf", kind: "pdf", sizeBytes: 482_000, chunks: 98 },
    ],
  };

  let info = $state<VaultInfo | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let mock = $state(false);

  async function load() {
    loading = true;
    error = null;
    const base = apiBase();
    if (base === null) {
      info = MOCK;
      mock = true;
      loading = false;
      return;
    }
    try {
      const res = await fetch(`${base}/api/vault`, { headers: { accept: "application/json" } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      info = (await res.json()) as VaultInfo;
      mock = false;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
    }
  }

  onMount(load);

  function fmtBytes(n: number): string {
    if (n < 1024) return `${n} B`;
    const u = ["KB", "MB", "GB", "TB"];
    let v = n / 1024;
    let i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return `${v.toFixed(v < 10 ? 1 : 0)} ${u[i]}`;
  }
</script>

<section class="vault">
  <header>
    <span>Vault</span>
    <button class="refresh" onclick={load} disabled={loading} title="Refresh">↻</button>
  </header>

  <div class="body">
    {#if loading && !info}
      <p class="muted">Loading…</p>
    {:else if error}
      <div class="error">
        <p>Couldn't load the vault: {error}</p>
        <p class="muted">Is the millfolio server running? Start it with <code>mill start</code>.</p>
      </div>
    {:else if info}
      {#if mock}
        <p class="banner">Sample data — open this from <code>mill start</code> (:10000) to see your real vault.</p>
      {/if}

      <div class="stats">
        <div class="stat">
          <span class="k">Files</span>
          <span class="v">{info.fileCount}</span>
        </div>
        <div class="stat">
          <span class="k">Indexed chunks</span>
          <span class="v">{info.chunkCount.toLocaleString()}</span>
        </div>
        <div class="stat">
          <span class="k">Index size</span>
          <span class="v">{fmtBytes(info.dbSizeBytes)}</span>
        </div>
        <div class="stat">
          <span class="k">Embedding dim</span>
          <span class="v">{info.embeddingDim}</span>
        </div>
        <div class="stat">
          <span class="k">Status</span>
          <span class="v">
            {#if info.indexed}
              <span class="dot ok"></span>indexed
            {:else}
              <span class="dot warn"></span>not indexed
            {/if}
          </span>
        </div>
        <div class="stat">
          <span class="k">Indexed files</span>
          <span class="v">{info.indexedFileCount}</span>
        </div>
      </div>

      <dl class="paths">
        <dt>Vault dir</dt>
        <dd><code>{info.vaultDir}</code></dd>
        <dt>Index</dt>
        <dd><code>{info.configDir}/index.db</code></dd>
      </dl>

      {#if info.files.length === 0}
        <p class="muted empty">
          No indexable files yet. Drop <code>.csv</code>, <code>.pdf</code>, or
          <code>.md</code> files in the vault dir, then run <code>mill index &lt;dir&gt;</code>.
        </p>
      {:else}
        <table>
          <thead>
            <tr>
              <th>File</th>
              <th class="num">Kind</th>
              <th class="num">Size</th>
              <th class="num">Chunks</th>
            </tr>
          </thead>
          <tbody>
            {#each info.files as f (f.alias)}
              <tr>
                <td class="name" title={f.alias}>{f.name}</td>
                <td class="num"><span class="kind {f.kind}">{f.kind}</span></td>
                <td class="num">{fmtBytes(f.sizeBytes)}</td>
                <td class="num">
                  {#if f.chunks > 0}{f.chunks}{:else}<span class="muted">—</span>{/if}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
        {#if !info.indexed}
          <p class="muted hint">Chunk counts appear after <code>mill index &lt;dir&gt;</code>.</p>
        {/if}
      {/if}
    {/if}
  </div>
</section>

<style>
  .vault {
    display: flex;
    flex-direction: column;
    min-height: 0;
    background: var(--surface);
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border);
    font-weight: 600;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-size: 11px;
  }
  .refresh {
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text-dim);
    border-radius: var(--radius);
    width: 26px;
    height: 26px;
    line-height: 1;
    font-size: 14px;
  }
  .refresh:hover:not(:disabled) {
    color: var(--text);
    border-color: var(--accent);
  }
  .refresh:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
  .body {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
  }
  .muted {
    color: var(--text-dim);
  }
  .empty {
    margin-top: 24px;
  }
  .hint {
    margin-top: 10px;
    font-size: 12px;
  }
  .banner {
    margin: 0 0 14px;
    padding: 8px 12px;
    border-radius: var(--radius);
    background: var(--surface-2);
    color: var(--text-dim);
    font-size: 12.5px;
  }
  .error {
    color: var(--err);
  }
  .error .muted {
    color: var(--text-dim);
  }
  .stats {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
    gap: 10px;
    margin-bottom: 16px;
  }
  .stat {
    background: var(--surface-2);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 10px 12px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .stat .k {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-dim);
  }
  .stat .v {
    font-size: 20px;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    display: inline-block;
  }
  .dot.ok {
    background: var(--ok);
  }
  .dot.warn {
    background: var(--warn);
  }
  .paths {
    margin: 0 0 18px;
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 4px 12px;
    font-size: 12.5px;
  }
  .paths dt {
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-size: 10px;
    align-self: center;
  }
  .paths dd {
    margin: 0;
    overflow-wrap: anywhere;
  }
  .paths code {
    color: var(--text-dim);
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }
  th,
  td {
    padding: 8px 10px;
    border-bottom: 1px solid var(--border);
    text-align: left;
  }
  th {
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-size: 10px;
    font-weight: 600;
  }
  .num {
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
  td.name {
    overflow-wrap: anywhere;
  }
  .kind {
    font-size: 11px;
    padding: 1px 7px;
    border-radius: 999px;
    background: var(--surface-2);
    border: 1px solid var(--border);
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .kind.csv {
    color: var(--accent);
  }
  .kind.pdf {
    color: var(--warn);
  }
  .kind.md {
    color: var(--ok);
  }
</style>
