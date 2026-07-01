<script lang="ts">
  import { onMount } from "svelte";
  import DefineTagModal from "./DefineTagModal.svelte";

  // The Tags view (a Vault sub-tab): the category rules that tag your transactions.
  // A plain filter narrows the list; "+ New tag" opens the define modal; each row is
  // edited/deleted IN PLACE on hover (no separate edit mode). `embedded` = rendered
  // inside VaultPanel's body (which already pads), so we drop our own outer padding.
  let { demo = false, embedded = false }: { demo?: boolean; embedded?: boolean } = $props();

  type Tag = {
    name: string;
    keywords: string[];
    description: string;
    ml: string; // the AI rule's yes/no question, "" for a keyword rule
    count: number;
  };
  let tags = $state<Tag[]>([]);
  let loaded = $state(false);
  let failed = $state(false);
  let saveMsg = $state("");
  let showModal = $state(false);

  function apiBase(): string {
    if (typeof location === "undefined") return "";
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    return "";
  }

  async function loadTags() {
    try {
      const r = await fetch(`${apiBase()}/api/tags`);
      if (!r.ok) throw new Error();
      tags = (await r.json()).tags ?? [];
      loaded = true;
    } catch {
      failed = true;
      loaded = true;
    }
  }
  onMount(loadTags);

  // Filter the list by tag name.
  let filter = $state("");
  const filteredTags = $derived.by(() => {
    const q = filter.trim().toLowerCase();
    if (!q) return tags;
    return tags.filter((t) => t.name.toLowerCase().includes(q));
  });

  const cleanName = (s: string) => s.replace(/[,=:()\t\n]/g, "").trim();
  const cleanDesc = (s: string) => s.replace(/[()\t\n]/g, "").trim();

  // Rebuild categories.txt from the tag list (same format the registry seeds).
  function tagsToText(ts: Tag[]): string {
    let out = "# millfolio category rules — edited in the Tags page.\n";
    for (const t of ts) {
      const name = cleanName(t.name);
      if (!name) continue;
      if (t.ml && t.ml.trim()) {
        out += `${name} : ${t.ml.trim()}\n`;
      } else {
        const desc = cleanDesc(t.description ?? "");
        const head = desc ? `${name} (${desc})` : name;
        const kw = (t.keywords ?? []).map((s) => s.trim()).filter(Boolean).join(", ");
        if (kw) out += `${head} = ${kw}\n`;
      }
    }
    return out;
  }

  async function persist(ts: Tag[], note: string) {
    saveMsg = "";
    try {
      const r = await fetch(`${apiBase()}/api/categories`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: tagsToText(ts) }),
      });
      const d = await r.json();
      if (!r.ok || !d.ok) throw new Error();
      const n = d.retagged ?? 0;
      saveMsg = `${note} — re-tagged ${n} transaction${n === 1 ? "" : "s"}.`;
      await loadTags();
    } catch {
      saveMsg = "Save failed.";
      await loadTags();
    }
  }

  // ── inline per-row edit ──────────────────────────────────────────────────────
  let editIdx = $state(-1);
  let eName = $state("");
  let eDesc = $state("");
  let eKw = $state("");
  let eMl = $state("");
  let eIsMl = $state(false);

  function startEdit(i: number) {
    const t = tags[i];
    editIdx = i;
    eName = t.name;
    eDesc = t.description ?? "";
    eKw = (t.keywords ?? []).join(", ");
    eMl = t.ml ?? "";
    eIsMl = !!t.ml;
    saveMsg = "";
  }
  function cancelEdit() {
    editIdx = -1;
  }
  async function saveEdit(i: number) {
    const next = tags.map((t, j) =>
      j === i
        ? {
            ...t,
            name: cleanName(eName),
            description: eIsMl ? "" : cleanDesc(eDesc),
            keywords: eIsMl ? [] : eKw.split(",").map((s) => s.trim()).filter(Boolean),
            ml: eIsMl ? eMl.trim() : "",
          }
        : t,
    );
    editIdx = -1;
    await persist(next, "Saved");
  }
  async function deleteTag(i: number) {
    const t = tags[i];
    if (typeof confirm === "function" && !confirm(`Delete the "${t.name}" tag?`)) return;
    const next = tags.filter((_, j) => j !== i);
    await persist(next, `Deleted “${t.name}”`);
  }

  // "define from this record" (opened by VaultPanel) reuses the modal; here we just
  // expose the New-tag button. The modal reloads the list on create.
</script>

<section class="tags" class:embedded>
  {#if !embedded}
    <header>
      <h2>Category tags</h2>
      <p class="meta">
        Rules that tag your transactions at index time — so "how much on phone" is a
        fast, exact filter. Hover a row to edit or delete it; the scope note is what
        the codegen model sees (with the name, never your keywords).
      </p>
    </header>
  {/if}

  {#if !loaded}
    <p class="muted">Loading…</p>
  {:else if failed}
    <p class="muted">Tags unavailable — start millfolio with <code>mill start</code>.</p>
  {:else}
    <div class="bar">
      <input class="filter" type="text" placeholder="Filter tags…" bind:value={filter} />
      {#if !demo}
        <button type="button" class="btn primary" onclick={() => (showModal = true)}>+ New tag</button>
      {/if}
      {#if saveMsg}<span class="savemsg">{saveMsg}</span>{/if}
    </div>

    {#if tags.length === 0}
      <p class="muted">No tags defined.</p>
    {:else}
      <table class="tagtable">
        <thead>
          <tr><th>Tag</th><th>Rule</th><th class="num">Txns</th><th class="act"></th></tr>
        </thead>
        <tbody>
          {#each filteredTags as t (t.name)}
            {@const i = tags.indexOf(t)}
            {#if editIdx === i}
              <tr class="editing">
                <td class="tname">
                  <input class="ein" bind:value={eName} placeholder="name" />
                </td>
                <td class="trule">
                  {#if eIsMl}
                    <input class="ein wide" bind:value={eMl} placeholder="yes/no question" />
                  {:else}
                    <input class="ein wide" bind:value={eKw} placeholder="keywords, comma-separated" />
                    <input class="ein wide" bind:value={eDesc} placeholder="scope note (optional)" />
                  {/if}
                </td>
                <td class="num">{t.count}</td>
                <td class="act">
                  <button type="button" class="mini save" onclick={() => saveEdit(i)}>Save</button>
                  <button type="button" class="mini" onclick={cancelEdit}>Cancel</button>
                </td>
              </tr>
            {:else}
              <tr>
                <td class="tname">
                  <span class="name">{t.name}</span>
                  {#if t.ml}<span class="mltag">AI</span>{/if}
                </td>
                <td class="trule">
                  {#if t.ml}
                    <span class="mlq">“{t.ml}”</span>
                  {:else}
                    {#if t.description}<span class="desc">{t.description}</span>{/if}
                    <span class="kw">{#each t.keywords as k}<span class="kchip">{k}</span>{/each}</span>
                  {/if}
                </td>
                <td class="num tcount">{t.count}</td>
                <td class="act">
                  {#if !demo}
                    <button type="button" class="mini" title="Edit" onclick={() => startEdit(i)} aria-label="Edit tag">✎</button>
                    <button type="button" class="mini del" title="Delete" onclick={() => deleteTag(i)} aria-label="Delete tag">✕</button>
                  {/if}
                </td>
              </tr>
            {/if}
          {/each}
        </tbody>
      </table>
      {#if filteredTags.length === 0}<p class="muted hint">No tags match “{filter}”.</p>{/if}
    {/if}
  {/if}
</section>

<DefineTagModal open={showModal} oncreated={loadTags} onclose={() => (showModal = false)} />

<style>
  .tags {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    max-width: 820px;
    margin: 0 auto;
    width: 100%;
  }
  .tags.embedded {
    padding: 0;
  }
  header {
    margin-bottom: 14px;
  }
  h2 {
    margin: 0;
    font-size: 16px;
  }
  .meta {
    margin: 4px 0 0;
    font-size: 12.5px;
    color: var(--text-dim);
    max-width: 64ch;
  }
  .bar {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 14px;
    flex-wrap: wrap;
  }
  .filter {
    flex: 1;
    min-width: 160px;
    padding: 8px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
  }
  .filter:focus {
    outline: none;
    border-color: var(--accent);
  }
  .savemsg {
    font-size: 12px;
    color: var(--ok);
  }
  .tagtable {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }
  .tagtable th,
  .tagtable td {
    padding: 8px 10px;
    border-bottom: 1px solid var(--border);
    text-align: left;
    vertical-align: top;
  }
  .tagtable th {
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-size: 10px;
    font-weight: 600;
  }
  .tagtable .num {
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
  .tagtable .act {
    width: 74px;
    text-align: right;
    white-space: nowrap;
  }
  .tname {
    white-space: nowrap;
  }
  .name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text);
  }
  .mltag {
    margin-left: 6px;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 999px;
    padding: 0 6px;
  }
  .tcount {
    color: var(--text-dim);
  }
  .desc {
    font-size: 12.5px;
    color: var(--text-dim);
  }
  .mlq {
    font-size: 12.5px;
    color: var(--text);
    font-style: italic;
  }
  .kw {
    display: inline-flex;
    flex-wrap: wrap;
    gap: 5px;
    margin-top: 4px;
  }
  .kchip {
    font-size: 11.5px;
    padding: 1px 7px;
    border-radius: var(--radius);
    background: var(--bg);
    border: 1px solid var(--border);
    color: var(--text-dim);
  }
  /* Edit/delete affordances — hidden until the row is hovered. */
  .act .mini {
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
  }
  tr:hover .act .mini {
    opacity: 1;
  }
  /* Touch devices can't hover — always show the row actions so they're tappable. */
  @media (hover: none) {
    .act .mini {
      opacity: 1;
    }
  }
  .act .mini:hover {
    border-color: var(--accent);
    color: var(--text);
  }
  .act .mini.del:hover {
    border-color: var(--err);
    color: var(--err);
  }
  /* Inline editor row — its buttons are always visible. */
  tr.editing .act .mini {
    opacity: 1;
  }
  .act .mini.save {
    color: var(--accent);
    font-weight: 600;
  }
  .ein {
    width: 140px;
    padding: 5px 8px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
  }
  .ein.wide {
    width: 100%;
    margin-bottom: 5px;
  }
  .ein:focus {
    outline: none;
    border-color: var(--accent);
  }
  .btn {
    padding: 7px 12px;
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
    color: #06101f;
    font-weight: 600;
  }
  .muted {
    color: var(--text-dim);
  }
  .hint {
    margin-top: 10px;
    font-size: 12px;
  }
  code {
    font-family: var(--mono);
  }
</style>
