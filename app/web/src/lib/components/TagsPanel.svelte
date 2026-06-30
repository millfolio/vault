<script lang="ts">
  import { onMount } from "svelte";

  // The Tags tab: the category tags that get stamped on your transactions at index
  // time (so "how much on phone" is a fast, exact filter), and an editor for the
  // rules. Everything is served in-process by the app server (vault.derive.store) —
  // the SAME registry the `millfolio` CLI uses; no model, no network.
  let { demo = false }: { demo?: boolean } = $props();

  type Tag = { name: string; keywords: string[]; count: number };
  let tags = $state<Tag[]>([]);
  let loaded = $state(false);
  let failed = $state(false);

  let editing = $state(false);
  let text = $state("");
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

  async function openEditor() {
    saveMsg = "";
    preview = null;
    try {
      const r = await fetch(`${apiBase()}/api/categories`);
      text = (await r.json()).text ?? "";
      editing = true;
    } catch {
      saveMsg = "Couldn't load the rules file.";
    }
  }

  // Validation dry-run: run the EDITED rules over the stored transactions without
  // saving — per-tag match counts + example descriptions, so you can spot a false
  // positive (or a rule that matches nothing) before committing. Deterministic
  // rules are exact here; an ML rule (`tag : question`) is evaluated at index time.
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
        body: JSON.stringify({ text }),
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
        body: JSON.stringify({ text }),
      });
      const d = await r.json();
      if (!r.ok || !d.ok) throw new Error();
      const n = d.retagged ?? 0;
      saveMsg = `Saved — re-tagged ${n} transaction${n === 1 ? "" : "s"}.`;
      editing = false;
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
      like "how much on phone" is a fast, exact filter, not a guess.
    </p>
  </header>

  {#if !loaded}
    <p class="muted">Loading…</p>
  {:else if failed}
    <p class="muted">Tags unavailable — start millfolio with <code>mill start</code>.</p>
  {:else}
    <div class="list">
      {#each tags as t}
        <div class="row">
          <div class="rhead">
            <span class="name">{t.name}</span>
            <span class="count">{t.count} txn{t.count === 1 ? "" : "s"}</span>
          </div>
          <div class="kw">
            {#each t.keywords as k}<span class="kchip">{k}</span>{/each}
          </div>
        </div>
      {/each}
      {#if tags.length === 0}<p class="muted">No tags defined.</p>{/if}
    </div>

    {#if !demo}
      <div class="edit">
        {#if !editing}
          <button type="button" class="btn" onclick={openEditor}>Edit categories…</button>
          <span class="edithint">add your own, or change the built-ins — then it re-tags</span>
        {:else}
          <p class="hint">
            One rule per line: <code>tag = keyword, keyword, …</code> (case-insensitive
            substring match), or an ML rule <code>tag : a yes/no question</code> the
            on-device model answers. Lines starting with <code>#</code> are comments.
            Saving re-tags immediately for keyword rules; <strong>ML rules materialize
            on the next index</strong> (they need the model).
          </p>
          <textarea bind:value={text} spellcheck="false" rows="14"></textarea>
          <div class="actions">
            <button type="button" class="btn primary" disabled={saving} onclick={save}>
              {saving ? "Saving…" : "Save & re-tag"}
            </button>
            <button type="button" class="btn" disabled={saving || previewing} onclick={doPreview}>
              {previewing ? "Checking…" : "Preview matches"}
            </button>
            <button type="button" class="btn" disabled={saving} onclick={() => { editing = false; preview = null; }}>
              Cancel
            </button>
          </div>
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
                      <span class="pml">ML · evaluated at index time</span>
                    {:else}
                      <span class="pcount">{p.count} txn{p.count === 1 ? "" : "s"}</span>
                    {/if}
                  </div>
                  {#if p.examples.length}
                    <ul class="pex">
                      {#each p.examples as ex}<li>{ex}</li>{/each}
                    </ul>
                  {:else if !p.ml}
                    <p class="pnone">no matches — check the keywords</p>
                  {/if}
                </div>
              {/each}
            </div>
          {/if}
        {/if}
        {#if saveMsg}<p class="savemsg">{saveMsg}</p>{/if}
      </div>
    {/if}
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
    max-width: 60ch;
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
  .count {
    font-size: 11.5px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
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
  .hint {
    font-size: 12.5px;
    color: var(--text-dim);
    margin: 0 0 8px;
  }
  textarea {
    width: 100%;
    box-sizing: border-box;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12.5px;
    line-height: 1.6;
    color: var(--text);
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 10px;
    resize: vertical;
  }
  .actions {
    display: flex;
    gap: 8px;
    margin-top: 10px;
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
