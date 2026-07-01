<script lang="ts">
  // Define-tag modal: name + a Keyword or AI rule, with a preview that DOESN'T
  // change compute (keyword = instant count; AI = a ~5s sample → "≈N of T match"),
  // then Create. Opened from the Tags sub-tab ("+ New tag") and from a record's
  // hover shortcut (pre-filled). Backed by /api/tags/{preview-ai,add} and, for the
  // keyword count, /api/categories/preview.
  type Mode = "keyword" | "ai";
  let {
    open = false,
    initialMode = "keyword",
    initialName = "",
    initialValue = "",
    oncreated,
    onclose,
  }: {
    open?: boolean;
    initialMode?: Mode;
    initialName?: string;
    initialValue?: string;
    oncreated?: () => void;
    onclose?: () => void;
  } = $props();

  function apiBase(): string {
    if (typeof location === "undefined") return "";
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    return "";
  }

  let mode = $state<Mode>("keyword");
  let name = $state("");
  let value = $state("");
  let msg = $state("");
  let creating = $state(false);
  let previewing = $state(false);
  type Preview = { matched: number; evaluated: number; total: number; exact: boolean };
  let preview = $state<Preview | null>(null);

  // Re-seed each time the modal opens (prefill from a record, or blank).
  let wasOpen = false;
  $effect(() => {
    if (open && !wasOpen) {
      mode = initialMode;
      name = initialName;
      value = initialValue;
      msg = "";
      preview = null;
    }
    wasOpen = open;
  });

  const projected = $derived(
    preview && preview.evaluated > 0
      ? Math.round((preview.matched / preview.evaluated) * preview.total)
      : 0,
  );

  async function runPreview() {
    const v = value.trim();
    if (!v) return;
    previewing = true;
    msg = "";
    preview = null;
    try {
      if (mode === "ai") {
        const r = await fetch(`${apiBase()}/api/tags/preview-ai`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ prompt: v }),
        });
        const d = await r.json();
        if (!r.ok) throw new Error(d.error ?? "preview failed");
        preview = { matched: d.matched, evaluated: d.evaluated, total: d.total, exact: d.evaluated >= d.total };
      } else {
        // Keyword rule: exact, instant dry-run over the stored transactions.
        const text = `${cleanName(name) || "tag"} = ${v}\n`;
        const r = await fetch(`${apiBase()}/api/categories/preview`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ text }),
        });
        const d = await r.json();
        const t = (d.tags ?? [])[0];
        const c = t ? t.count : 0;
        preview = { matched: c, evaluated: 0, total: 0, exact: true };
      }
    } catch (e) {
      msg = e instanceof Error ? e.message : "Preview failed.";
    }
    previewing = false;
  }

  const cleanName = (s: string) => s.replace(/[,=:()\t\n]/g, "").trim();

  async function create() {
    const n = cleanName(name);
    const v = value.trim();
    if (!n) { msg = "Give the tag a name."; return; }
    if (!v) { msg = mode === "ai" ? "Enter a yes/no question." : "Enter one or more keywords."; return; }
    creating = true;
    msg = "";
    try {
      const body = mode === "ai" ? { name: n, prompt: v } : { name: n, keywords: v };
      const r = await fetch(`${apiBase()}/api/tags/add`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const d = await r.json();
      if (!r.ok || !d.ok) throw new Error(d.error ?? "create failed");
      if (mode === "ai") {
        // An AI rule tags nothing synchronously — kick materialization so it starts.
        fetch(`${apiBase()}/api/materialize/run`, { method: "POST" }).catch(() => {});
      }
      oncreated?.();
      onclose?.();
    } catch (e) {
      msg = e instanceof Error ? e.message : "Create failed.";
    }
    creating = false;
  }

  function onKeydown(e: KeyboardEvent) {
    if (e.key === "Escape") onclose?.();
  }
</script>

<svelte:window onkeydown={(e) => { if (open) onKeydown(e); }} />

{#if open}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="backdrop" role="presentation" onclick={(e) => { if (e.target === e.currentTarget) onclose?.(); }}>
    <div class="modal" role="dialog" aria-modal="true" aria-label="Define a tag">
      <h3>New tag</h3>

      <div class="seg" role="tablist" aria-label="Rule type">
        <button role="tab" aria-selected={mode === "keyword"} class:on={mode === "keyword"} onclick={() => { mode = "keyword"; preview = null; }}>Keyword</button>
        <button role="tab" aria-selected={mode === "ai"} class:on={mode === "ai"} onclick={() => { mode = "ai"; preview = null; }}>AI</button>
      </div>

      <label class="fld">
        <span>Tag name</span>
        <input type="text" placeholder="e.g. gym" bind:value={name} />
      </label>

      <label class="fld">
        <span>{mode === "ai" ? "Yes/no question" : "Keywords (comma-separated)"}</span>
        <input
          type="text"
          placeholder={mode === "ai" ? "is this a gym or fitness membership?" : "planet fitness, equinox, gym"}
          bind:value={value}
          oninput={() => (preview = null)}
        />
      </label>

      <div class="row">
        <button type="button" class="btn" onclick={runPreview} disabled={previewing || !value.trim()}>
          {previewing ? "Previewing…" : "Preview"}
        </button>
        {#if preview}
          <span class="pv">
            {#if preview.exact}
              <strong>{preview.matched}</strong> record{preview.matched === 1 ? "" : "s"} match{preview.matched === 1 ? "es" : ""}.
            {:else}
              ≈<strong>{projected}</strong> of {preview.total} could match
              <span class="dim">(sampled {preview.evaluated}, nothing saved)</span>
            {/if}
          </span>
        {/if}
      </div>

      {#if msg}<p class="msg">{msg}</p>{/if}

      <div class="actions">
        <button type="button" class="btn" onclick={() => onclose?.()}>Cancel</button>
        <button type="button" class="btn primary" onclick={create} disabled={creating || !name.trim() || !value.trim()}>
          {creating ? "Creating…" : "Create tag"}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 60;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 20px;
    background: rgba(0, 0, 0, 0.55);
  }
  .modal {
    width: 100%;
    max-width: 440px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px 22px;
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.4);
  }
  h3 {
    margin: 0 0 14px;
    font-size: 15px;
  }
  .seg {
    display: inline-flex;
    gap: 2px;
    padding: 2px;
    margin-bottom: 14px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--surface-2);
  }
  .seg button {
    border: none;
    background: transparent;
    color: var(--text-dim);
    font: inherit;
    font-size: 12.5px;
    font-weight: 600;
    padding: 5px 16px;
    border-radius: calc(var(--radius) - 2px);
    cursor: pointer;
  }
  .seg button.on {
    background: var(--accent);
    color: #06101f;
  }
  .fld {
    display: block;
    margin-bottom: 12px;
  }
  .fld span {
    display: block;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-dim);
    margin-bottom: 5px;
  }
  .fld input {
    width: 100%;
    padding: 8px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
    font: inherit;
  }
  .fld input:focus {
    outline: none;
    border-color: var(--accent);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 4px 0 6px;
    flex-wrap: wrap;
  }
  .pv {
    font-size: 12.5px;
    color: var(--text);
  }
  .pv .dim {
    color: var(--text-dim);
  }
  .msg {
    margin: 6px 0 0;
    font-size: 12px;
    color: var(--warn);
  }
  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 16px;
  }
  .btn {
    padding: 7px 14px;
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
</style>
