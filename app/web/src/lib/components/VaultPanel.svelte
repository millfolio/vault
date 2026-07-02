<script lang="ts">
  // Vault view — the indexable files in your vault dir + LanceDB index stats,
  // from the local server's GET /api/vault. Read-only; refreshable.
  import { onMount } from "svelte";
  import { untrack } from "svelte";
  import SubTabs from "./SubTabs.svelte";
  import TagsPanel from "./TagsPanel.svelte";
  import DefineTagModal from "./DefineTagModal.svelte";
  import { unlockAmounts as revealUnlock } from "$lib/reveal";

  // Vault sub-tabs: Records | Tags | Files. `initialSub` lets /tags deep-link open
  // the Tags sub-tab (the tag pills link there).
  let {
    demo = false,
    initialSub = "records",
  }: { demo?: boolean; initialSub?: string } = $props();

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
    year: number; // statement year (0 = unknown → show the bare M/D)
    amount: number | null; // null = withheld until the Touch-ID gate is passed
    direction: string;
    desc: string;
    tags: string[];
  }
  const MOCK_TXNS: Txn[] = [
    { file: "file_2", date: "4/03", year: 2026, amount: 85.0, direction: "debit", desc: "VERIZON WIRELESS", tags: ["phone"] },
    { file: "file_2", date: "4/11", year: 2026, amount: 52.1, direction: "credit", desc: "PAYROLL DEPOSIT", tags: [] },
    { file: "file_2", date: "4/18", year: 2026, amount: 128.44, direction: "debit", desc: "WHOLE FOODS MARKET", tags: ["groceries"] },
    { file: "file_0", date: "4/22", year: 2026, amount: 410.0, direction: "debit", desc: "DELTA AIR LINES", tags: ["travel"] },
  ];

  // The date with its statement year appended when known (4/03 → 4/03/2026).
  function fmtDate(t: Txn): string {
    return t.year > 0 ? `${t.date}/${t.year}` : t.date;
  }

  // Files | Records sub-view switch inside the Vault tab.
  let sub = $state<"files" | "records" | "tags">(
    untrack(() => (initialSub === "tags" || initialSub === "files" ? initialSub : "records")),
  );
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

  onMount(() => {
    load();
    if (sub === "records") loadTxns(); // Records is the default sub-tab
  });

  // Amounts are WITHHELD by the server until the Touch-ID gate is passed (privacy
  // screen). Until then every `amount` is null → the UI shows ••••; on unlock we
  // re-fetch with ?amounts=1 to bring the real figures in.
  let unlocked = $state(false);
  let unlocking = $state(false);
  let unlockErr = $state("");
  let showUnlock = $state(false); // the passphrase prompt is open
  let pwInput = $state(""); // the passphrase the user is typing
  let revealToken = ""; // the server-issued bearer token that authorizes ?amounts=1

  // Fetch the extracted transactions — with amounts only once unlocked. `force`
  // re-fetches even if already loaded (used right after unlocking).
  async function loadTxns(force = false) {
    if (txLoaded && !force) return;
    txLoaded = true;
    txLoading = true;
    txError = null;
    // Sample data (dev) and the public demo have nothing to protect — the demo
    // server serves amounts unconditionally, so treat it as already unlocked.
    if (demo) unlocked = true;
    const base = apiBase();
    if (base === null) {
      txns = MOCK_TXNS;
      unlocked = true;
      txLoading = false;
      return;
    }
    try {
      const q = unlocked ? "?amounts=1" : "";
      const headers: Record<string, string> = { accept: "application/json" };
      if (unlocked && revealToken) headers.Authorization = `Bearer ${revealToken}`;
      const res = await fetch(`${base}/api/transactions${q}`, { headers });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      txns = ((await res.json()).transactions ?? []) as Txn[];
    } catch (e) {
      txError = e instanceof Error ? e.message : String(e);
    } finally {
      txLoading = false;
    }
  }

  // "Show amounts" opens a passphrase prompt (the token lives only in memory, so a
  // reload re-prompts — no persisted unlock).
  function openUnlock() {
    unlockErr = "";
    pwInput = "";
    showUnlock = true;
  }
  function cancelUnlock() {
    showUnlock = false;
    unlockErr = "";
    pwInput = "";
  }
  async function submitUnlock() {
    if (unlocking || !pwInput.trim()) return;
    unlocking = true;
    unlockErr = "";
    try {
      revealToken = await revealUnlock(pwInput);
      unlocked = true;
      showUnlock = false;
      pwInput = "";
      await loadTxns(true); // re-fetch, now with the reveal token → amounts
    } catch (e) {
      unlockErr = e instanceof Error ? e.message : "Unlock failed.";
    } finally {
      unlocking = false;
    }
  }
  function lockAmounts() {
    unlocked = false;
    revealToken = "";
    loadTxns(true); // re-fetch without amounts (drop the figures from memory)
  }
  function showRecords() {
    sub = "records";
    loadTxns();
  }

  // Plain text-filter over the loaded records (by description).
  let recFilter = $state("");
  const filteredTxns = $derived.by(() => {
    const all = txns ?? [];
    const q = recFilter.trim().toLowerCase();
    if (!q) return all;
    return all.filter((t) => t.desc.toLowerCase().includes(q));
  });
  // Totals over the CURRENTLY-SHOWN (filtered) records — only meaningful once
  // unlocked (amounts present). Recomputed as you filter, so "spent on X" falls out.
  const totals = $derived.by(() => {
    let out = 0, inc = 0;
    for (const t of filteredTxns) {
      if (typeof t.amount === "number") {
        if (t.direction === "debit") out += t.amount;
        else inc += t.amount;
      }
    }
    return { out, inc, net: inc - out };
  });
  const money = (n: number) =>
    "$" + Math.abs(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  // Re-pull records + tags after a tag is created (retag changes the .tags column).
  async function reloadAfterTag() {
    txLoaded = false;
    await loadTxns();
    await load();
  }

  // "Define a tag from this record" — opens the modal pre-filled from the merchant.
  let modalOpen = $state(false);
  let modalName = $state("");
  let modalValue = $state("");
  function defineFromRecord(desc: string) {
    modalValue = desc;
    modalName = (desc.trim().toLowerCase().match(/[a-z0-9]+/)?.[0] ?? "");
    modalOpen = true;
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
  // Short label for the Records → File link — the LAST n chars (keeps the date/
  // extension suffix, which distinguishes statements); full name stays in the title.
  function abbrev(s: string, n = 12): string {
    return s.length > n ? "…" + s.slice(-n) : s;
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
      <SubTabs
        tabs={[
          { id: "records", label: "Records" },
          { id: "tags", label: "Tags" },
          { id: "files", label: "Files" },
        ]}
        active={sub}
        onselect={(id) => (id === "records" ? showRecords() : (sub = id as "files" | "tags"))}
      />
      {#if sub === "tags"}
        <TagsPanel {demo} embedded />
      {:else if sub === "files"}
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
              <a
                class="tagchip tclick"
                href="/tags"
                title={`${t.count} transaction${t.count === 1 ? "" : "s"} — edit in Tags`}
              >
                {t.name}<span class="tcount">{t.count}</span>
              </a>
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
          <div class="recbar">
            <input class="filter" type="text" placeholder="Filter records…" bind:value={recFilter} />
            {#if !mock && !demo}
              {#if unlocked}
                <button type="button" class="lockbtn" onclick={lockAmounts} title="Hide amounts again">🔓 Hide amounts</button>
              {:else if !showUnlock}
                <button type="button" class="lockbtn primary" onclick={openUnlock}>🔒 Show amounts</button>
              {/if}
            {/if}
          </div>
          {#if showUnlock && !unlocked}
            <form class="unlock" onsubmit={(e) => { e.preventDefault(); submitUnlock(); }}>
              <!-- svelte-ignore a11y_autofocus -->
              <input
                class="pw"
                type="password"
                autocomplete="off"
                autofocus
                placeholder="Amount passphrase"
                bind:value={pwInput}
              />
              <button type="submit" class="lockbtn primary" disabled={unlocking || !pwInput.trim()}>
                {unlocking ? "Checking…" : "Unlock"}
              </button>
              <button type="button" class="lockbtn" onclick={cancelUnlock}>Cancel</button>
              <span class="pwhint">Forgot it? <code>mill get amount-password</code></span>
            </form>
          {/if}
          <p class="reccount">
            {#if recFilter.trim()}
              {filteredTxns.length} of {txns.length} records
            {:else}
              {txns.length} record{txns.length === 1 ? "" : "s"}
            {/if}
          </p>
          {#if unlockErr}<p class="banner warn">{unlockErr}</p>{/if}
          {#if unlocked}
            <div class="totals" role="status">
              <span class="tl"><span class="k">Spent</span><span class="v out">{money(totals.out)}</span></span>
              <span class="tl"><span class="k">Received</span><span class="v inc">{money(totals.inc)}</span></span>
              <span class="tl"><span class="k">Net</span><span class="v" class:out={totals.net < 0}>{totals.net < 0 ? "-" : ""}{money(totals.net)}</span></span>
              <span class="tnote">{filteredTxns.length} record{filteredTxns.length === 1 ? "" : "s"}{recFilter.trim() ? " (filtered)" : ""}</span>
            </div>
          {/if}
          <table class="records">
            <thead>
              <tr>
                <th>Date</th>
                <th>Description</th>
                <th class="num">Amount</th>
                <th>Tags</th>
                <th>File</th>
                <th class="act"></th>
              </tr>
            </thead>
            <tbody>
              {#each filteredTxns as t, i (i)}
                <tr>
                  <td class="date">{fmtDate(t)}</td>
                  <td class="desc">{t.desc}</td>
                  <td class="num amt" class:out={t.direction === "debit"}>
                    {#if t.amount === null}<span class="masked" title="Locked — Show amounts">••••</span>{:else}{fmtMoney(t.amount, t.direction)}{/if}
                  </td>
                  <td class="tags">
                    {#if t.tags.length > 0}
                      <span class="rchips">
                        {#each t.tags as tag}
                          <a class="tagchip rchip tclick" href="/tags" title="Edit in Tags">{tag}</a>
                        {/each}
                      </span>
                    {:else}
                      <span class="muted">—</span>
                    {/if}
                  </td>
                  <td class="rfile">
                    {#if !mock && fileFor(t.file)}
                      <button type="button" class="filelink" onclick={() => openHit(t.file)} title={nameFor(t.file)}>
                        <span class="open" aria-hidden="true">↗</span>{abbrev(nameFor(t.file))}
                      </button>
                    {:else}
                      <span class="muted" title={nameFor(t.file)}>{abbrev(nameFor(t.file))}</span>
                    {/if}
                  </td>
                  <td class="act">
                    {#if !mock && !demo}
                      <button type="button" class="mini" title="Define a tag from this merchant" aria-label="Define a tag from this record" onclick={() => defineFromRecord(t.desc)}>+ tag</button>
                    {/if}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
          {#if filteredTxns.length === 0}
            <p class="muted hint">No records match “{recFilter}”.</p>
          {/if}
        {:else}
          <p class="muted empty">No transactions extracted yet — index statement files.</p>
        {/if}
      {/if}
    {/if}
  </div>
</section>

<DefineTagModal
  open={modalOpen}
  initialMode="keyword"
  initialName={modalName}
  initialValue={modalValue}
  oncreated={reloadAfterTag}
  onclose={() => (modalOpen = false)}
/>

<style>
  .recbar {
    display: flex;
    margin-bottom: 14px;
  }
  .recbar .filter {
    flex: 1;
    padding: 8px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
  }
  .recbar .filter:focus {
    outline: none;
    border-color: var(--accent);
  }
  .reccount {
    margin: 0 0 12px;
    font-size: 12px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .lockbtn {
    flex: none;
    padding: 8px 14px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text);
    cursor: pointer;
    font: inherit;
    font-size: 13px;
    white-space: nowrap;
  }
  .lockbtn:hover {
    border-color: var(--accent);
  }
  .lockbtn.primary {
    background: var(--accent);
    border-color: var(--accent);
    color: #06101f;
    font-weight: 600;
  }
  .lockbtn:disabled {
    opacity: 0.6;
    cursor: default;
  }
  .unlock {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin: 0 0 12px;
  }
  .unlock .pw {
    flex: 0 1 220px;
    padding: 8px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font: inherit;
  }
  .unlock .pw:focus {
    outline: none;
    border-color: var(--accent);
  }
  .pwhint {
    font-size: 12px;
    color: var(--text-dim);
  }
  .pwhint code {
    font-family: var(--mono);
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 1px 5px;
    font-size: 11.5px;
  }
  .masked {
    letter-spacing: 2px;
    color: var(--text-dim);
    user-select: none;
  }
  .totals {
    display: flex;
    align-items: baseline;
    gap: 20px;
    flex-wrap: wrap;
    margin-bottom: 14px;
    padding: 10px 14px;
    background: var(--surface-2);
    border: 1px solid var(--border);
    border-radius: var(--radius);
  }
  .totals .tl {
    display: inline-flex;
    align-items: baseline;
    gap: 7px;
  }
  .totals .k {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-dim);
  }
  .totals .v {
    font-size: 15px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }
  .totals .v.inc {
    color: var(--ok);
  }
  .totals .v.out {
    color: var(--err);
  }
  .totals .tnote {
    margin-left: auto;
    font-size: 11.5px;
    color: var(--text-dim);
  }
  .records .act {
    width: 58px;
    text-align: right;
  }
  .records .act .mini {
    opacity: 0;
    transition: opacity 0.12s ease;
    border: 1px solid transparent;
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
    font: inherit;
    font-size: 12px;
    padding: 2px 6px;
    border-radius: var(--radius);
    white-space: nowrap;
  }
  .records tr:hover .act .mini {
    opacity: 1;
  }
  /* Touch devices can't hover — always show the per-record action so it's tappable. */
  @media (hover: none) {
    .records .act .mini {
      opacity: 1;
    }
  }
  .records .act .mini:hover {
    border-color: var(--accent);
    color: var(--accent);
  }
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
  a.tagchip {
    text-decoration: none;
  }
  a.tagchip.tclick {
    cursor: pointer;
    transition: border-color 0.12s ease, color 0.12s ease;
  }
  a.tagchip.tclick:hover {
    border-color: var(--accent);
    color: var(--accent);
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
  a.rchip.tclick {
    text-decoration: none;
    cursor: pointer;
  }
  a.rchip.tclick:hover {
    border-color: var(--accent);
    background: var(--surface-2);
  }
  .records td.rfile {
    overflow-wrap: anywhere;
    max-width: 220px;
  }
  .records td.rfile .muted {
    font-size: 12px;
  }
  button.filelink {
    background: none;
    border: none;
    padding: 0;
    margin: 0;
    color: var(--accent);
    cursor: pointer;
    font: inherit;
    font-size: 12.5px;
    text-align: left;
    overflow-wrap: anywhere;
  }
  button.filelink:hover {
    text-decoration: underline;
  }
</style>
