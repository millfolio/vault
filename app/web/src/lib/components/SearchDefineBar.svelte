<script lang="ts">
  // Unified search + tag-definition bar. One query, two modes:
  //   • String — an instant substring match; the parent filters its list live.
  //   • AI     — a yes/no prompt the on-device model answers; not live (too slow),
  //              but "Preview" runs a ~5s sample and reports how many records match.
  // Either query can be saved as a category tag (keyword rule for String, AI rule
  // for AI) via a 5-second preview that does NOT change compute, then Create tag.
  // Reused on Vault → Records and on the Tags screen.
  type Mode = "string" | "ai";
  let {
    onfilter,
    ontagcreated,
    stringPlaceholder = "Search records…",
  }: {
    onfilter?: (query: string, mode: Mode) => void;
    ontagcreated?: () => void;
    stringPlaceholder?: string;
  } = $props();

  function apiBase(): string {
    if (typeof location === "undefined") return "";
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    return "";
  }

  let mode = $state<Mode>("string");
  let query = $state("");
  let defining = $state(false);
  let tagName = $state("");
  let msg = $state("");

  type Preview = { matched: number; evaluated: number; total: number };
  let preview = $state<Preview | null>(null);
  let previewing = $state(false);
  let creating = $state(false);

  const projected = $derived(
    preview && preview.evaluated > 0
      ? Math.round((preview.matched / preview.evaluated) * preview.total)
      : 0,
  );
  const previewExact = $derived(!!preview && preview.evaluated >= preview.total);

  function setMode(m: Mode) {
    if (mode === m) return;
    mode = m;
    preview = null;
    msg = "";
    // Leaving String mode clears the parent's live filter; entering it re-applies.
    onfilter?.(m === "string" ? query : "", m);
  }

  function onInput() {
    preview = null;
    msg = "";
    if (mode === "string") onfilter?.(query, "string");
  }

  async function runPreview() {
    const p = query.trim();
    if (!p) return;
    previewing = true;
    msg = "";
    preview = null;
    try {
      const r = await fetch(`${apiBase()}/api/tags/preview-ai`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prompt: p }),
      });
      const d = await r.json();
      if (!r.ok) throw new Error(d.error ?? "preview failed");
      preview = d as Preview;
    } catch (e) {
      msg = e instanceof Error ? e.message : "Preview failed.";
    }
    previewing = false;
  }

  function startDefine() {
    defining = true;
    msg = "";
    if (!tagName) tagName = suggestName();
  }
  // A default tag name from the query — the first word, lowercased.
  function suggestName(): string {
    const w = query.trim().toLowerCase().replace(/[^a-z0-9 ].*$/, "").trim().split(/\s+/)[0];
    return w ?? "";
  }

  async function createTag() {
    const name = tagName.trim();
    const q = query.trim();
    if (!name || !q) {
      msg = "Give the tag a name.";
      return;
    }
    creating = true;
    msg = "";
    try {
      const body =
        mode === "ai" ? { name, prompt: q } : { name, keywords: q };
      const r = await fetch(`${apiBase()}/api/tags/add`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const d = await r.json();
      if (!r.ok || !d.ok) throw new Error(d.error ?? "create failed");
      // An AI rule tags nothing synchronously — kick a materialization slice so it
      // starts right away (best-effort; the System → Materialization tab tracks it).
      if (mode === "ai") {
        fetch(`${apiBase()}/api/materialize/run`, { method: "POST" }).catch(() => {});
        msg = `Created “${name}” — materializing over your records…`;
      } else {
        msg = `Created “${name}” — tagged ${d.retagged} record${d.retagged === 1 ? "" : "s"}.`;
      }
      defining = false;
      ontagcreated?.();
    } catch (e) {
      msg = e instanceof Error ? e.message : "Create failed.";
    }
    creating = false;
  }

  function cancelDefine() {
    defining = false;
    msg = "";
  }
</script>

<div class="sd">
  <div class="sdrow">
    <div class="modeseg" role="tablist" aria-label="Search mode">
      <button role="tab" aria-selected={mode === "string"} class:on={mode === "string"} onclick={() => setMode("string")}>Text</button>
      <button role="tab" aria-selected={mode === "ai"} class:on={mode === "ai"} onclick={() => setMode("ai")}>AI</button>
    </div>
    <input
      type="text"
      placeholder={mode === "string" ? stringPlaceholder : "Ask a yes/no question, e.g. is this a gym?"}
      bind:value={query}
      oninput={onInput}
    />
    {#if mode === "ai"}
      <button type="button" class="btn" onclick={runPreview} disabled={previewing || !query.trim()}>
        {previewing ? "Previewing…" : "Preview"}
      </button>
    {/if}
    <button type="button" class="btn primary" onclick={startDefine} disabled={!query.trim()}>
      + Define tag
    </button>
  </div>

  {#if preview}
    <div class="pv">
      {#if previewExact}
        <strong>{preview.matched}</strong> of {preview.total} records match this rule.
      {:else}
        ≈<strong>{projected}</strong> of {preview.total} records could match
        <span class="dim">— sampled {preview.evaluated} in ~5s (preview only, nothing saved)</span>
      {/if}
    </div>
  {/if}

  {#if defining}
    <div class="defrow">
      <span class="dlabel">{mode === "ai" ? "AI rule" : "keyword rule"} name</span>
      <input class="nameinput" type="text" placeholder="tag name" bind:value={tagName} />
      <button type="button" class="btn primary" onclick={createTag} disabled={creating || !tagName.trim()}>
        {creating ? "Creating…" : "Create tag"}
      </button>
      <button type="button" class="btn" onclick={cancelDefine}>Cancel</button>
    </div>
  {/if}
  {#if msg}<p class="msg">{msg}</p>{/if}
</div>

<style>
  .sd {
    margin-bottom: 14px;
  }
  .sdrow {
    display: flex;
    gap: 8px;
    align-items: center;
    flex-wrap: wrap;
  }
  .modeseg {
    display: inline-flex;
    gap: 2px;
    padding: 2px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--surface-2);
    flex: none;
  }
  .modeseg button {
    border: none;
    background: transparent;
    color: var(--text-dim);
    font: inherit;
    font-size: 12px;
    font-weight: 600;
    padding: 4px 10px;
    border-radius: calc(var(--radius) - 2px);
    cursor: pointer;
  }
  .modeseg button.on {
    background: var(--accent);
    color: #06101f;
  }
  .sdrow input {
    flex: 1;
    min-width: 160px;
    padding: 8px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
  }
  .sdrow input:focus {
    outline: none;
    border-color: var(--accent);
  }
  .btn {
    flex: none;
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
  .btn:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .pv {
    margin-top: 9px;
    font-size: 12.5px;
    color: var(--text);
  }
  .pv .dim {
    color: var(--text-dim);
  }
  .defrow {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin-top: 10px;
    padding-top: 10px;
    border-top: 1px solid var(--border);
  }
  .dlabel {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-dim);
  }
  .nameinput {
    padding: 6px 10px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    width: 160px;
  }
  .nameinput:focus {
    outline: none;
    border-color: var(--accent);
  }
  .msg {
    margin: 8px 0 0;
    font-size: 12px;
    color: var(--text-dim);
  }
</style>
