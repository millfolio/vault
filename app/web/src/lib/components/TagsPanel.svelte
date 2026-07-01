<script lang="ts">
  import { onMount } from "svelte";

  // The Tags tab: the category tags stamped on your transactions at index time (so
  // "how much on phone" is a fast, exact filter). Edited INLINE here — one row per
  // tag (name, scope note, keywords or an AI question) — and saved by reconstructing
  // the categories.txt the app server's in-process registry reads (no model, no
  // network). The note is the disambiguator sent to the codegen model (never the
  // keywords) so it picks the right tag — that's the gym-vs-health fix.
  let { demo = false }: { demo?: boolean } = $props();

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

  // Structured edit draft — one editable row per tag.
  type Row = { name: string; description: string; kw: string; ml: string; isMl: boolean };
  let editing = $state(false);
  let rows = $state<Row[]>([]);
  let saving = $state(false);
  let saveMsg = $state("");

  // Same-origin in production; an explicit ?api=… wins; Vite dev (:5173) has no backend.
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

  function openEditor() {
    saveMsg = "";
    preview = null;
    rows = tags.map((t) => ({
      name: t.name,
      description: t.description ?? "",
      kw: (t.keywords ?? []).join(", "),
      ml: t.ml ?? "",
      isMl: !!t.ml,
    }));
    editing = true;
  }
  function cancelEdit() {
    editing = false;
    preview = null;
    saveMsg = "";
  }
  function addRow() {
    rows = [...rows, { name: "", description: "", kw: "", ml: "", isMl: false }];
  }
  function removeRow(i: number) {
    rows = rows.filter((_, j) => j !== i);
    preview = null;
  }

  // A tag name can't hold a separator (',' '=' ':' parens); a description can't hold
  // parens (they delimit `tag (note) = …`). Strip them so a stray char can't corrupt
  // the file — mirrors the registry's own validation.
  const cleanName = (s: string) => s.replace(/[,=:()\t\n]/g, "").trim();
  const cleanDesc = (s: string) => s.replace(/[()\t\n]/g, "").trim();

  // Reconstruct categories.txt from the rows (the same format the registry seeds).
  function rowsToText(rs: Row[]): string {
    let out = "# millfolio category rules — edited in the Tags page.\n";
    for (const r of rs) {
      const name = cleanName(r.name);
      if (!name) continue;
      const desc = cleanDesc(r.description);
      const head = desc ? `${name} (${desc})` : name;
      if (r.isMl) {
        // An AI rule's question IS its scope — never attach a separate description
        // (it'd be redundant/confusing when displayed).
        const q = r.ml.trim();
        if (q) out += `${name} : ${q}\n`;
      } else {
        const kw = r.kw
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean)
          .join(", ");
        if (kw) out += `${head} = ${kw}\n`;
      }
    }
    return out;
  }

  // Validation dry-run over the stored transactions, WITHOUT saving: per-tag match
  // counts + example descriptions, so you can spot a false positive (or a no-match
  // rule) before committing. Keyword rules are exact; an AI rule is index-time.
  type PreviewTag = { name: string; ml: boolean; count: number; examples: string[] };
  let preview = $state<PreviewTag[] | null>(null);
  let previewing = $state(false);
  async function doPreview() {
    previewing = true;
    saveMsg = "";
    try {
      const r = await fetch(`${apiBase()}/api/categories/preview`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: rowsToText(rows) }),
      });
      preview = ((await r.json()).tags ?? []) as PreviewTag[];
    } catch {
      saveMsg = "Couldn't preview the rules.";
    }
    previewing = false;
  }

  async function save() {
    saving = true;
    saveMsg = "";
    try {
      const r = await fetch(`${apiBase()}/api/categories`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: rowsToText(rows) }),
      });
      const d = await r.json();
      if (!r.ok || !d.ok) throw new Error();
      const n = d.retagged ?? 0;
      saveMsg = `Saved — re-tagged ${n} transaction${n === 1 ? "" : "s"}.`;
      editing = false;
      preview = null;
      await loadTags();
    } catch {
      saveMsg = "Save failed.";
    }
    saving = false;
  }

  onMount(loadTags);
</script>

<section class="tags">
  <header>
    <h2>Category tags</h2>
    <p class="meta">
      Deterministic rules that tag your transactions at index time — so a question
      like "how much on phone" is a fast, exact filter, not a guess. The scope note
      is what the codegen model sees (with the name, never your keywords) so it picks
      the right tag.
    </p>
  </header>

  {#if !loaded}
    <p class="muted">Loading…</p>
  {:else if failed}
    <p class="muted">Tags unavailable — start millfolio with <code>mill start</code>.</p>
  {:else if !editing}
    <!-- ── read-only list ── -->
    <div class="list">
      {#each tags as t}
        <div class="row">
          <div class="rhead">
            <span class="name">{t.name}</span>
            {#if t.ml}<span class="mltag">AI rule</span>{/if}
            <span class="count">{t.count} txn{t.count === 1 ? "" : "s"}</span>
          </div>
          {#if t.description && !t.ml}<p class="desc">{t.description}</p>{/if}
          {#if t.ml}
            <p class="mlq">“{t.ml}”</p>
          {:else}
            <div class="kw">
              {#each t.keywords as k}<span class="kchip">{k}</span>{/each}
            </div>
          {/if}
        </div>
      {/each}
      {#if tags.length === 0}<p class="muted">No tags defined.</p>{/if}
    </div>

    {#if !demo}
      <div class="edit">
        <button type="button" class="btn" onclick={openEditor}>Edit tags…</button>
        <span class="edithint">add your own, tweak the built-ins, or write a scope note — then it re-tags</span>
        {#if saveMsg}<p class="savemsg">{saveMsg}</p>{/if}
      </div>
    {/if}
  {:else}
    <!-- ── inline structured editor ── -->
    <div class="editor">
      <p class="hint">
        One row per tag. <strong>Keywords</strong> are case-insensitive substring
        matches (comma-separated). The <strong>scope note</strong> disambiguates the
        tag for the model. Toggle <strong>AI rule</strong> to classify by a yes/no
        question instead (evaluated on-device at index time).
      </p>

      {#each rows as r, i (i)}
        <div class="erow">
          <div class="eline">
            <input class="ename" placeholder="tag name" bind:value={r.name} spellcheck="false" />
            <label class="mltoggle" title="Classify with the on-device model instead of keywords">
              <input type="checkbox" bind:checked={r.isMl} /> AI rule
            </label>
            <button type="button" class="del" title="Delete tag" aria-label="Delete tag" onclick={() => removeRow(i)}>×</button>
          </div>
          {#if !r.isMl}
            <input
              class="edesc"
              placeholder="scope note (shown to the model) — e.g. pharmacies, doctors; NOT gyms"
              bind:value={r.description}
              spellcheck="false"
            />
          {/if}
          {#if r.isMl}
            <input
              class="ekw"
              placeholder="yes/no question — e.g. is this a gym or fitness studio?"
              bind:value={r.ml}
              spellcheck="false"
            />
          {:else}
            <input
              class="ekw"
              placeholder="keywords, comma, separated — e.g. verizon, at&t, t-mobile"
              bind:value={r.kw}
              spellcheck="false"
            />
          {/if}
        </div>
      {/each}

      <button type="button" class="btn addrow" onclick={addRow}>+ Add tag</button>

      <div class="actions">
        <button type="button" class="btn primary" disabled={saving} onclick={save}>
          {saving ? "Saving…" : "Save & re-tag"}
        </button>
        <button type="button" class="btn" disabled={saving || previewing} onclick={doPreview}>
          {previewing ? "Checking…" : "Preview matches"}
        </button>
        <button type="button" class="btn" disabled={saving} onclick={cancelEdit}>Cancel</button>
      </div>
      {#if saveMsg}<p class="savemsg">{saveMsg}</p>{/if}

      {#if preview}
        <div class="preview">
          <p class="phint">
            What these rules would tag in your stored transactions — <em>not saved yet</em>.
            Eyeball the examples for false positives before you save.
          </p>
          {#each preview as p}
            <div class="prow">
              <div class="phead">
                <span class="pname">{p.name}</span>
                {#if p.ml}
                  <span class="pml">AI · evaluated at index time</span>
                {:else}
                  <span class="pcount">{p.count} txn{p.count === 1 ? "" : "s"}</span>
                {/if}
              </div>
              {#if p.examples.length}
                <ul class="pex">{#each p.examples as ex}<li>{ex}</li>{/each}</ul>
              {:else if !p.ml}
                <p class="pnone">no matches — check the keywords</p>
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</section>

<style>
  .tags {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    max-width: 820px;
    margin: 0 auto;
    width: 100%;
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
  .list {
    display: flex;
    flex-direction: column;
  }
  .row {
    padding: 10px 0;
    border-top: 1px solid var(--border);
  }
  .rhead {
    display: flex;
    align-items: baseline;
    gap: 10px;
  }
  .name {
    font-size: 14px;
    font-weight: 600;
    color: var(--text);
  }
  .mltag {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 999px;
    padding: 0 6px;
  }
  .count {
    font-size: 11.5px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .desc {
    margin: 3px 0 0;
    font-size: 12px;
    color: var(--text-dim);
  }
  .mlq {
    margin: 4px 0 0;
    font-size: 12.5px;
    color: var(--text);
    font-style: italic;
  }
  .kw {
    display: flex;
    flex-wrap: wrap;
    gap: 5px;
    margin-top: 6px;
  }
  .kchip {
    font-size: 11.5px;
    padding: 1px 7px;
    border-radius: var(--radius);
    background: var(--bg);
    border: 1px solid var(--border);
    color: var(--text-dim);
  }
  .edit {
    margin-top: 20px;
    padding-top: 14px;
    border-top: 1px solid var(--border);
  }
  .edithint {
    margin-left: 10px;
    font-size: 12px;
    color: var(--text-dim);
  }
  /* editor */
  .editor {
    margin-top: 6px;
  }
  .hint {
    font-size: 12.5px;
    color: var(--text-dim);
    margin: 0 0 12px;
    max-width: 64ch;
  }
  .erow {
    display: flex;
    flex-direction: column;
    gap: 5px;
    padding: 10px 0;
    border-top: 1px solid var(--border);
  }
  .eline {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .ename {
    flex: 1;
    font-weight: 600;
  }
  .mltoggle {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 12px;
    color: var(--text-dim);
    white-space: nowrap;
  }
  .del {
    flex: none;
    width: 26px;
    height: 26px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
    font-size: 16px;
    line-height: 1;
  }
  .del:hover {
    color: var(--err, #f85149);
    border-color: var(--err, #f85149);
  }
  .ename,
  .edesc,
  .ekw {
    width: 100%;
    box-sizing: border-box;
    font-family: inherit;
    font-size: 12.5px;
    color: var(--text);
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 6px 9px;
  }
  .edesc,
  .ekw {
    color: var(--text-dim);
  }
  .erow input:focus {
    outline: none;
    border-color: var(--accent);
  }
  .addrow {
    margin-top: 12px;
  }
  .actions {
    display: flex;
    gap: 8px;
    margin-top: 16px;
    flex-wrap: wrap;
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
  .savemsg {
    margin: 10px 0 0;
    font-size: 12.5px;
    color: var(--accent);
  }
  /* preview */
  .preview {
    margin-top: 14px;
    padding-top: 12px;
    border-top: 1px solid var(--border);
  }
  .phint {
    margin: 0 0 10px;
    font-size: 12px;
    color: var(--text-dim);
  }
  .prow {
    padding: 8px 0;
    border-top: 1px solid var(--border);
  }
  .prow:first-of-type {
    border-top: none;
  }
  .phead {
    display: flex;
    align-items: baseline;
    gap: 10px;
  }
  .pname {
    font-size: 13px;
    font-weight: 600;
  }
  .pcount {
    font-size: 11.5px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .pml {
    font-size: 11px;
    color: var(--accent);
  }
  .pex {
    margin: 5px 0 0;
    padding-left: 18px;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .pex li {
    font-size: 11.5px;
    color: var(--text-dim);
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    overflow-wrap: anywhere;
  }
  .pnone {
    margin: 4px 0 0;
    font-size: 11.5px;
    color: var(--warn, #d29922);
  }
  .muted {
    color: var(--text-dim);
  }
  code {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 0.92em;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 0 4px;
  }
</style>
