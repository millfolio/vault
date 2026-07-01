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
    vaultDir: string; // the dir the server serves (chat/ask read this)
    sourceDir: string; // the dir the index was actually built from
    dirMismatch: boolean; // sourceDir != vaultDir → chat/ask point at the wrong files
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
    // Vite dev (:5173) has no backend → sample data. Every other origin is served
    // by millfolio-server (localhost:10000 OR an https Tailscale/proxy host), so
    // the API is same-origin. (port===10000 alone missed the Tailscale HTTPS case.)
    if (location.port === "5173") return null;
    return "";
  }

  const MOCK: VaultInfo = {
    vaultDir: "~/.config/millfolio/vault",
    sourceDir: "~/.config/millfolio/vault",
    dirMismatch: false,
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

  interface SearchHit {
    alias: string;
    score: number;
    text: string;
  }

  // Category tags stamped on transactions at index time (GET /api/tags). Shown
  // read-only here so the vault view surfaces the derived attributes, not just
  // file aliases; the full editor lives in the Tags tab.
  interface Tag {
    name: string;
    count: number;
  }
  const MOCK_TAGS: Tag[] = [
    { name: "phone", count: 12 },
    { name: "travel", count: 34 },
    { name: "groceries", count: 88 },
  ];
  let tags = $state<Tag[]>([]);

  // One extracted, reconciled transaction (GET /api/transactions) — the exact rows
  // the app sums, each with its derived category tags. `amount` is a non-negative
  // magnitude; the sign is in `direction` ("debit" = money out, "credit" = in).
  interface Txn {
    file: string;
    date: string;
    amount: number;
    direction: string;
    desc: string;
    tags: string[];
  }
  const MOCK_TXNS: Txn[] = [
    { file: "file_2", date: "4/03", amount: 85.0, direction: "debit", desc: "VERIZON WIRELESS", tags: ["phone"] },
    { file: "file_2", date: "4/11", amount: 52.1, direction: "credit", desc: "PAYROLL DEPOSIT", tags: [] },
    { file: "file_2", date: "4/18", amount: 128.44, direction: "debit", desc: "WHOLE FOODS MARKET", tags: ["groceries"] },
    { file: "file_0", date: "4/22", amount: 410.0, direction: "debit", desc: "DELTA AIR LINES", tags: ["travel"] },
  ];

  // Files | Records sub-view switch inside the Vault tab.
  let sub = $state<"files" | "records">("files");
  let txns = $state<Txn[] | null>(null);
  let txLoading = $state(false);
  let txError = $state<string | null>(null);
  let txLoaded = false; // fetched lazily on the first switch to Records

  let info = $state<VaultInfo | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let mock = $state(false);
  // The document currently open in the viewer (null = list view).
  let viewing = $state<VaultFile | null>(null);

  // URL the viewer points at — the server streams the raw indexed file by alias
  // (frontier-safe: alias → real path resolved server-side from the manifest).
  function docUrl(f: VaultFile): string {
    const base = apiBase() ?? "";
    return `${base}/api/doc?alias=${encodeURIComponent(f.alias)}`;
  }
  function openDoc(f: VaultFile) {
    if (mock) return; // no backend in dev/sample mode
    viewing = f;
  }
  function closeDoc() {
    viewing = null;
  }
  let query = $state("");
  let hits = $state<SearchHit[] | null>(null);
  let searching = $state(false);
  let searchErr = $state<string | null>(null);

  async function load() {
    loading = true;
    error = null;
    const base = apiBase();
    if (base === null) {
      info = MOCK;
      tags = MOCK_TAGS;
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
    // Best-effort — the tag strip just disappears if tags can't be loaded.
    try {
      const r = await fetch(`${base}/api/tags`, { headers: { accept: "application/json" } });
      if (r.ok) tags = ((await r.json()).tags ?? []) as Tag[];
    } catch {
      /* leave tags empty */
    }
  }

  onMount(load);

  // Lazily fetch the extracted transactions the first time Records is opened.
  async function loadTxns() {
    if (txLoaded) return;
    txLoaded = true;
    txLoading = true;
    txError = null;
    const base = apiBase();
    if (base === null) {
      txns = MOCK_TXNS;
      txLoading = false;
      return;
    }
    try {
      const res = await fetch(`${base}/api/transactions`, { headers: { accept: "application/json" } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      txns = ((await res.json()).transactions ?? []) as Txn[];
    } catch (e) {
      txError = e instanceof Error ? e.message : String(e);
    } finally {
      txLoading = false;
    }
  }
  function showRecords() {
    sub = "records";
    loadTxns();
  }

  // A signed, formatted amount: debit = money OUT (−), credit = money IN (+).
  function fmtMoney(amount: number, direction: string): string {
    const sign = direction === "debit" ? "-" : "+";
    const abs = Math.abs(amount).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    return `${sign}$${abs}`;
  }

  // Map a hit's frontier-safe alias back to its real filename (from the manifest).
  function nameFor(alias: string): string {
    return info?.files.find((f) => f.alias === alias)?.name ?? alias;
  }
  // The indexed file behind a hit's alias (for opening it in the viewer).
  function fileFor(alias: string): VaultFile | undefined {
    return info?.files.find((f) => f.alias === alias);
  }
  // Open the document a search hit came from, in the in-app viewer.
  function openHit(alias: string) {
    const f = fileFor(alias);
    if (f) openDoc(f);
  }

  async function runSearch(e: SubmitEvent) {
    e.preventDefault();
    const q = query.trim();
    if (!q) {
      hits = null;
      return;
    }
    searching = true;
    searchErr = null;
    const base = apiBase();
    if (base === null) {
      // dev / no backend → sample result
      hits = [
        { alias: "file_0", score: 0.74, text: "Sample hit — run via mill start to search your real vault." },
      ];
      searching = false;
      return;
    }
    try {
      const res = await fetch(`${base}/api/search`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ query: q, k: 8 }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      hits = (data.hits ?? []) as SearchHit[];
    } catch (err) {
      searchErr = err instanceof Error ? err.message : String(err);
      hits = null;
    } finally {
      searching = false;
    }
  }

  function clearSearch() {
    query = "";
    hits = null;
    searchErr = null;
  }

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
  {#if viewing}
    <div class="viewer">
      <header class="vbar">
        <button class="back" onclick={closeDoc} aria-label="Back to vault">←</button>
        <span class="vtitle" title={viewing.name}>{viewing.name}</span>
        <span class="kind {viewing.kind}">{viewing.kind}</span>
        <a class="newtab" href={docUrl(viewing)} target="_blank" rel="noopener">Open ↗</a>
      </header>
      <iframe class="frame" src={docUrl(viewing)} title={viewing.name}></iframe>
    </div>
  {/if}
  <div class="body" class:hidden={viewing}>
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
      <div class="subtabs" role="tablist">
        <button role="tab" aria-selected={sub === "files"} class:active={sub === "files"} onclick={() => (sub = "files")}>
          Files
        </button>
        <button role="tab" aria-selected={sub === "records"} class:active={sub === "records"} onclick={showRecords}>
          Records
        </button>
      </div>
      {#if sub === "files"}
      <form class="search" onsubmit={runSearch}>
        <input
          type="text"
          placeholder="Search your vault…"
          bind:value={query}
          disabled={searching}
        />
        <button type="submit" disabled={searching || !query.trim()}>
          {searching ? "…" : "Search"}
        </button>
        {#if hits !== null}
          <button type="button" class="clear" onclick={clearSearch}>Clear</button>
        {/if}
      </form>
      {#if searchErr}
        <p class="banner warn">Search failed: {searchErr}</p>
      {/if}
      {#if hits !== null}
        <div class="results">
          {#if hits.length === 0}
            <p class="muted">No matches.</p>
          {:else}
            {#each hits as h (h.alias + h.score)}
              <div class="hit">
                <div class="hmeta">
                  {#if !mock && fileFor(h.alias)}
                    <button type="button" class="hname link" onclick={() => openHit(h.alias)} title="View document">
                      <span class="open" aria-hidden="true">↗</span>{nameFor(h.alias)}
                    </button>
                  {:else}
                    <span class="hname">{nameFor(h.alias)}</span>
                  {/if}
                  <span class="hscore">{h.score.toFixed(3)}</span>
                </div>
                <p class="hsnip">{h.text}</p>
              </div>
            {/each}
          {/if}
        </div>
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

      {#if hits === null}
      {#if tags.length > 0}
        <div class="tagstrip">
          <div class="tshead">
            <span class="tslabel">Category tags</span>
            <a class="tslink" href="/tags">edit →</a>
          </div>
          <div class="tschips">
            {#each tags as t}
              <span class="tagchip" title={`${t.count} transaction${t.count === 1 ? "" : "s"}`}>
                {t.name}<span class="tcount">{t.count}</span>
              </span>
            {/each}
          </div>
          <p class="tshint">
            Stamped on your transactions at index time — so "how much on phone" is a fast,
            exact filter. The frontier model is told these tag <em>names</em> (never your
            keyword rules).
          </p>
        </div>
      {/if}
      <dl class="paths">
        <dt>Indexed from</dt>
        <dd><code>{info.sourceDir || info.vaultDir}</code></dd>
        <dt>Serving</dt>
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
              <tr class:clickable={!mock} onclick={() => openDoc(f)}>
                <td class="name" title={mock ? f.alias : "View document"}>
                  {#if !mock}<span class="open" aria-hidden="true">↗</span>{/if}{f.name}
                </td>
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
      {:else}
        <!-- Records: the extracted, reconciled transactions the app sums. -->
        {#if txLoading && txns === null}
          <p class="muted">Loading…</p>
        {:else if txError}
          <p class="banner warn">Couldn't load transactions: {txError}</p>
        {:else if txns && txns.length > 0}
          <table class="records">
            <thead>
              <tr>
                <th>Date</th>
                <th>Description</th>
                <th class="num">Amount</th>
                <th>Tags</th>
              </tr>
            </thead>
            <tbody>
              {#each txns as t, i (i)}
                <tr>
                  <td class="date">{t.date}</td>
                  <td class="desc">{t.desc}</td>
                  <td class="num amt" class:out={t.direction === "debit"}>{fmtMoney(t.amount, t.direction)}</td>
                  <td class="tags">
                    {#if t.tags.length > 0}
                      <span class="rchips">
                        {#each t.tags as tag}
                          <span class="tagchip rchip">{tag}</span>
                        {/each}
                      </span>
                    {:else}
                      <span class="muted">—</span>
                    {/if}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        {:else}
          <p class="muted empty">No transactions extracted yet — index statement files.</p>
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
  .body {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
  }
  .body.hidden {
    display: none;
  }

  /* document viewer */
  .viewer {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  .vbar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
  }
  .vbar .back {
    border: 1px solid var(--border);
    background: var(--surface-2);
    color: var(--text);
    border-radius: var(--radius);
    width: 30px;
    height: 30px;
    font-size: 16px;
    flex: none;
  }
  .vtitle {
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
    min-width: 0;
  }
  .vbar .newtab {
    flex: none;
    font-size: 12.5px;
    color: var(--accent);
    text-decoration: none;
    padding: 5px 10px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
  }
  .frame {
    flex: 1;
    min-height: 0;
    width: 100%;
    border: 0;
    background: var(--bg);
  }
  tr.clickable {
    cursor: pointer;
  }
  tr.clickable:hover td {
    background: var(--surface-2);
  }
  .open {
    color: var(--text-dim);
    margin-right: 6px;
    font-size: 11px;
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
  .banner.warn {
    color: var(--warn);
    border: 1px solid var(--warn);
    background: transparent;
  }
  .search {
    display: flex;
    gap: 8px;
    margin-bottom: 14px;
  }
  .search input {
    flex: 1;
    padding: 8px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
  }
  .search input:focus {
    outline: none;
    border-color: var(--accent);
  }
  .search button {
    padding: 8px 14px;
    border-radius: var(--radius);
    border: none;
    background: var(--accent);
    color: #06101f;
    font-weight: 600;
  }
  .search button.clear {
    background: transparent;
    border: 1px solid var(--border);
    color: var(--text-dim);
  }
  .search button:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
  .results {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-bottom: 8px;
  }
  .hit {
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 10px 12px;
    background: var(--surface-2);
  }
  .hmeta {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 10px;
    margin-bottom: 4px;
  }
  .hname {
    font-weight: 600;
    overflow-wrap: anywhere;
  }
  button.hname.link {
    background: none;
    border: none;
    padding: 0;
    margin: 0;
    color: var(--accent);
    cursor: pointer;
    font: inherit;
    font-weight: 600;
    text-align: left;
  }
  button.hname.link:hover {
    text-decoration: underline;
  }
  .hscore {
    font-size: 11px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .hsnip {
    margin: 0;
    font-size: 12.5px;
    color: var(--text-dim);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    max-height: 7.5em;
    overflow: hidden;
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
  .tagstrip {
    margin: 0 0 18px;
    padding: 12px 14px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--surface-2);
  }
  .tshead {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    margin-bottom: 9px;
  }
  .tslabel {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-dim);
    font-weight: 600;
  }
  .tslink {
    font-size: 12px;
    color: var(--accent);
    text-decoration: none;
  }
  .tslink:hover {
    text-decoration: underline;
  }
  .tschips {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .tagchip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    padding: 2px 6px 2px 9px;
    border-radius: 999px;
    background: var(--bg);
    border: 1px solid var(--border);
    color: var(--text);
  }
  .tcount {
    font-size: 10.5px;
    font-variant-numeric: tabular-nums;
    color: var(--text-dim);
    background: var(--surface-2);
    border-radius: 999px;
    padding: 0 6px;
  }
  .tshint {
    margin: 9px 0 0;
    font-size: 11.5px;
    color: var(--text-dim);
    line-height: 1.5;
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

  /* Files | Records sub-tab switch */
  .subtabs {
    display: inline-flex;
    gap: 2px;
    padding: 2px;
    margin-bottom: 14px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--surface-2);
  }
  .subtabs button {
    border: none;
    background: transparent;
    color: var(--text-dim);
    font: inherit;
    font-size: 12.5px;
    font-weight: 600;
    padding: 5px 14px;
    border-radius: calc(var(--radius) - 2px);
    cursor: pointer;
  }
  .subtabs button.active {
    background: var(--accent);
    color: #06101f;
  }

  /* Records table */
  .records td.date {
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .records td.desc {
    overflow-wrap: anywhere;
  }
  .records td.amt {
    font-variant-numeric: tabular-nums;
    font-weight: 600;
    white-space: nowrap;
  }
  .records td.amt.out {
    color: var(--err);
  }
  .rchips {
    display: inline-flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .rchip {
    font-size: 11px;
    padding: 1px 9px;
    color: var(--accent);
  }
</style>
