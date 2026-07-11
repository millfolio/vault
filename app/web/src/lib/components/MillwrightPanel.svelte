<script lang="ts">
  import { onMount } from "svelte";
  import ResultView from "./ResultView.svelte";
  import type { MillfolioClient, ResultSpec, ServerEvent } from "$lib/protocol";

  // Millwright — the versioned, user-owned dashboard (designs/MILLWRIGHT.md).
  // This component is TRUSTED CHROME: it is hand-written and interprets the
  // generated spec as data. The spec never carries markup or URLs (the server
  // lints that before a version is accepted); every string renders as text.

  let { client, demo = false }: { client: MillfolioClient; demo?: boolean } = $props();

  type Widget = { id: string; title: string; q?: string; w?: number; h?: number };
  type Spec = {
    v: number;
    kind: string;
    widgets: Widget[];
    layout?: { cols?: number; order?: string[] };
  };
  type Snapshot = { ts: number; result: ResultSpec; preview?: boolean };
  type Version = { hash: string; parent: string; ts: number; author: string; message: string };

  let spec = $state<Spec | null>(null);
  let active = $state("");
  let results = $state<Record<string, Snapshot>>({});
  let loadError = $state("");

  // chrome drawers
  let showSpec = $state(false);
  let specDraft = $state("");
  let specError = $state("");
  let showVersions = $state(false);
  let versions = $state<Version[]>([]);
  let refreshing = $state<Record<string, boolean>>({});

  async function load() {
    loadError = "";
    try {
      const r = await fetch("/api/millwright");
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const d = await r.json();
      spec = d?.spec ?? null;
      active = d?.active ?? "";
      results = d?.results ?? {};
    } catch (e) {
      loadError = String(e);
    }
  }
  onMount(load);

  // Widgets in layout order (unknown/missing order entries fall back to spec order).
  const ordered = $derived.by(() => {
    if (!spec) return [] as Widget[];
    const byId = new Map(spec.widgets.map((w) => [w.id, w]));
    const out: Widget[] = [];
    for (const id of spec.layout?.order ?? []) {
      const w = byId.get(id);
      if (w) {
        out.push(w);
        byId.delete(id);
      }
    }
    for (const w of spec.widgets) if (byId.has(w.id)) out.push(w);
    return out;
  });
  const cols = $derived(Math.min(Math.max(spec?.layout?.cols ?? 2, 1), 6));

  function asOf(id: string): string {
    if (results[id]?.preview) return "example data — ↻ to run on your vault";
    const ts = results[id]?.ts;
    if (!ts) return "not run yet";
    const d = new Date(ts * 1000);
    const days = Math.floor((Date.now() / 1000 - ts) / 86400);
    if (days <= 0) return "as of today";
    if (days === 1) return "as of yesterday";
    return `as of ${d.toLocaleDateString()}`;
  }

  // ── refresh: re-run the widget's PINNED program through the existing
  // deterministic run path (same machinery as history's "Run again"), then
  // store the fresh result as the widget's snapshot. No model call.
  async function refresh(id: string) {
    if (demo || refreshing[id]) return;
    try {
      const r = await fetch(`/api/millwright/program?id=${encodeURIComponent(id)}`);
      if (!r.ok) return;
      const { program } = await r.json();
      const q = spec?.widgets.find((w) => w.id === id)?.q ?? "";
      refreshing = { ...refreshing, [id]: true };
      const done = (ok: boolean, result?: ResultSpec) => {
        refreshing = { ...refreshing, [id]: false };
        if (ok && result) {
          fetch("/api/millwright/result", {
            method: "POST",
            body: JSON.stringify({ id, result }),
          }).then(load);
        }
      };
      let settled = false;
      client.run(program, q, (e: ServerEvent) => {
        if (settled) return;
        if (e.type === "message") {
          settled = true;
          done(true, (e as any).result);
        } else if (e.type === "error") {
          settled = true;
          done(false);
        }
      });
      // Belt-and-braces: a run that never answers must not pin the spinner.
      setTimeout(() => {
        if (!settled) {
          settled = true;
          done(false);
        }
      }, 180_000);
    } catch {
      refreshing = { ...refreshing, [id]: false };
    }
  }

  // ── spec chrome: view/edit + versions + revert (all trusted, hand-written) ──
  function openSpec() {
    specDraft = JSON.stringify(spec, null, 2);
    specError = "";
    showSpec = true;
    showVersions = false;
  }
  async function saveSpec() {
    specError = "";
    try {
      const r = await fetch("/api/millwright/spec", {
        method: "POST",
        body: JSON.stringify({ spec: specDraft, message: "hand-edited spec" }),
      });
      const d = await r.json();
      if (!r.ok || d?.error) {
        specError = d?.error ?? `HTTP ${r.status}`;
        return; // invalid specs never become versions — the board keeps rendering
      }
      showSpec = false;
      await load();
    } catch (e) {
      specError = String(e);
    }
  }
  async function removeWidget(w: Widget) {
    if (!spec) return;
    const next: Spec = {
      ...spec,
      widgets: spec.widgets.filter((x) => x.id !== w.id),
      layout: {
        ...(spec.layout ?? {}),
        order: (spec.layout?.order ?? []).filter((id) => id !== w.id),
      },
    };
    await fetch("/api/millwright/spec", {
      method: "POST",
      body: JSON.stringify({ spec: next, message: `removed "${w.title}"` }),
    });
    await load();
  }
  async function openVersions() {
    showVersions = true;
    showSpec = false;
    try {
      const r = await fetch("/api/millwright/versions");
      const d = await r.json();
      versions = (d?.versions ?? []).map((v: any) => ({
        hash: String(v.hash ?? ""),
        parent: String(v.parent ?? ""),
        ts: Number(v.ts ?? 0),
        author: String(v.author ?? ""),
        message: String(v.message ?? ""),
      }));
      active = d?.active ?? active;
    } catch {}
  }
  // ── model-assisted edit: the instruction goes to the frontier via the
  // server (privacy-box transport); the reply is linted by the same validator
  // as a hand edit before it becomes a version. Errors surface verbatim.
  let assistDraft = $state("");
  let assistBusy = $state(false);
  let assistNote = $state("");
  async function assist() {
    const instruction = assistDraft.trim();
    if (!instruction || assistBusy) return;
    assistBusy = true;
    assistNote = "";
    try {
      const r = await fetch("/api/millwright/assist", {
        method: "POST",
        body: JSON.stringify({ instruction }),
      });
      const d = await r.json();
      if (!r.ok || d?.error) {
        assistNote = d?.error ?? `HTTP ${r.status}`;
      } else {
        assistNote = d?.message ? `✓ ${d.message}` : "✓ done";
        assistDraft = "";
        await load();
      }
    } catch (e) {
      assistNote = String(e);
    } finally {
      assistBusy = false;
    }
  }

  async function revertTo(hash: string) {
    await fetch("/api/millwright/revert", {
      method: "POST",
      body: JSON.stringify({ hash }),
    });
    await load();
    await openVersions();
  }
</script>

<div class="board">
  <div class="board-head">
    <h2>Board</h2>
    <div class="board-actions">
      {#if !demo}
        <button type="button" class="chrome-btn" class:on={showSpec} onclick={() => (showSpec ? (showSpec = false) : openSpec())} title="See and edit the spec this board is made of">spec</button>
        <button type="button" class="chrome-btn" class:on={showVersions} onclick={() => (showVersions ? (showVersions = false) : openVersions())} title="Every version of this board — diff and revert">history</button>
      {/if}
    </div>
  </div>

  {#if !demo && ordered.length > 0}
    <div class="assist">
      <input
        class="assist-in"
        type="text"
        placeholder="Change the board… (e.g. “three columns, groceries first”)"
        bind:value={assistDraft}
        disabled={assistBusy}
        onkeydown={(e) => e.key === "Enter" && assist()}
      />
      <button type="button" class="chrome-btn" disabled={assistBusy || !assistDraft.trim()} onclick={assist}>
        {assistBusy ? "editing…" : "edit with AI"}
      </button>
      {#if assistNote}<span class="assist-note" class:err={!assistNote.startsWith("✓")}>{assistNote}</span>{/if}
    </div>
  {/if}

  {#if loadError}
    <p class="board-err">Couldn't load the board: {loadError}</p>
  {:else if ordered.length === 0}
    <p class="board-empty">
      {#if demo}
        Nothing here yet — the demo board is read-only.
      {:else}
        Nothing pinned yet. Ask a question in <a href="/">Chat</a> — answers with a
        chart or table get a <strong>Pin</strong> button that adds them here.
      {/if}
    </p>
  {:else}
    <div class="grid" style={`grid-template-columns: repeat(${cols}, minmax(0, 1fr))`}>
      {#each ordered as w (w.id)}
        <section class="tile" style={`grid-column: span ${Math.min(w.w ?? 1, cols)}`}>
          <header class="tile-head">
            <h3 title={w.q ?? w.title}>{w.title}{#if results[w.id]?.preview}<span class="preview-badge">example</span>{/if}</h3>
            <div class="tile-tools">
              <span class="stamp">{asOf(w.id)}</span>
              {#if !demo}
                <button type="button" class="tool" disabled={refreshing[w.id]} title="Re-run this widget's saved program over your current vault — no model call" onclick={() => refresh(w.id)}>{refreshing[w.id] ? "…" : "↻"}</button>
                <button type="button" class="tool" title="Remove from the board (the version history keeps it)" onclick={() => removeWidget(w)}>×</button>
              {/if}
            </div>
          </header>
          <svelte:boundary>
            {#if results[w.id]?.result}
              <ResultView result={results[w.id].result} />
            {:else}
              <p class="pending">No result yet — hit ↻ to run it.</p>
            {/if}
            {#snippet failed()}
              <p class="pending">This widget's result couldn't render. ↻ to re-run it.</p>
            {/snippet}
          </svelte:boundary>
        </section>
      {/each}
    </div>
  {/if}

  {#if showSpec}
    <div class="drawer">
      <div class="drawer-head">
        <h3>The spec</h3>
        <span class="ver">v {active.slice(0, 8)}</span>
      </div>
      <p class="drawer-hint">
        This board is made of this spec — data, not code. Edit it and save; an
        invalid spec is rejected before it ever renders.
      </p>
      <textarea class="spec-edit" bind:value={specDraft} rows={16} spellcheck="false"></textarea>
      {#if specError}<p class="board-err">{specError}</p>{/if}
      <div class="drawer-actions">
        <button type="button" class="chrome-btn" onclick={saveSpec}>save</button>
        <button type="button" class="chrome-btn" onclick={() => (showSpec = false)}>cancel</button>
      </div>
    </div>
  {/if}

  {#if showVersions}
    <div class="drawer">
      <div class="drawer-head"><h3>History</h3></div>
      {#if versions.length === 0}
        <p class="drawer-hint">No versions yet.</p>
      {:else}
        <ul class="vers">
          {#each versions as v (v.hash)}
            <li class="ver-li" class:active={v.hash === active}>
              <code>{v.hash.slice(0, 8)}</code>
              <span class="ver-msg">{v.message}</span>
              <span class="ver-meta">{v.author} · {new Date(v.ts * 1000).toLocaleString()}</span>
              {#if v.hash === active}
                <span class="ver-now">active</span>
              {:else}
                <button type="button" class="tool" title="Make this the active board" onclick={() => revertTo(v.hash)}>revert</button>
              {/if}
            </li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}
</div>

<style>
  .board {
    padding: 1rem 1.25rem 2rem;
    max-width: 72rem;
    margin: 0 auto;
  }
  .board-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    margin-bottom: 0.75rem;
  }
  .board-head h2 {
    margin: 0;
    font-size: 1.1rem;
  }
  .board-actions {
    display: flex;
    gap: 0.4rem;
  }
  .chrome-btn {
    font: inherit;
    font-size: 0.8rem;
    padding: 0.15rem 0.6rem;
    border: 1px solid color-mix(in srgb, currentColor 25%, transparent);
    border-radius: 0.4rem;
    background: transparent;
    color: inherit;
    cursor: pointer;
  }
  .chrome-btn.on {
    background: color-mix(in srgb, currentColor 12%, transparent);
  }
  .assist {
    display: flex;
    gap: 0.4rem;
    align-items: center;
    margin-bottom: 0.8rem;
  }
  .assist-in {
    flex: 1;
    font: inherit;
    font-size: 0.85rem;
    padding: 0.3rem 0.55rem;
    border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
    border-radius: 0.45rem;
    background: transparent;
    color: inherit;
  }
  .assist-note {
    font-size: 0.78rem;
    opacity: 0.75;
  }
  .assist-note.err {
    color: #c0392b;
  }
  .board-empty,
  .pending {
    opacity: 0.7;
    font-size: 0.9rem;
  }
  .board-err {
    color: #c0392b;
    font-size: 0.85rem;
  }
  .grid {
    display: grid;
    gap: 0.8rem;
  }
  .tile {
    border: 1px solid color-mix(in srgb, currentColor 15%, transparent);
    border-radius: 0.6rem;
    padding: 0.7rem 0.85rem;
    min-width: 0;
    overflow-x: auto;
  }
  .tile-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 0.5rem;
    margin-bottom: 0.35rem;
  }
  .tile-head h3 {
    margin: 0;
    font-size: 0.92rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .tile-tools {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    flex: none;
  }
  .preview-badge {
    font-size: 0.62rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    opacity: 0.55;
    border: 1px solid color-mix(in srgb, currentColor 30%, transparent);
    border-radius: 0.3rem;
    padding: 0 0.3rem;
    margin-left: 0.4rem;
    vertical-align: middle;
  }
  .stamp {
    font-size: 0.72rem;
    opacity: 0.55;
  }
  .tool {
    font: inherit;
    font-size: 0.8rem;
    border: none;
    background: transparent;
    color: inherit;
    opacity: 0.6;
    cursor: pointer;
    padding: 0 0.15rem;
  }
  .tool:hover {
    opacity: 1;
  }
  .drawer {
    margin-top: 1rem;
    border: 1px solid color-mix(in srgb, currentColor 15%, transparent);
    border-radius: 0.6rem;
    padding: 0.8rem 1rem;
  }
  .drawer-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
  }
  .drawer-head h3 {
    margin: 0 0 0.3rem;
    font-size: 0.95rem;
  }
  .ver {
    font-size: 0.75rem;
    opacity: 0.6;
    font-family: ui-monospace, monospace;
  }
  .drawer-hint {
    font-size: 0.8rem;
    opacity: 0.65;
    margin: 0.2rem 0 0.6rem;
  }
  .spec-edit {
    width: 100%;
    font-family: ui-monospace, monospace;
    font-size: 0.78rem;
    border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
    border-radius: 0.4rem;
    background: transparent;
    color: inherit;
    padding: 0.5rem;
    box-sizing: border-box;
  }
  .drawer-actions {
    display: flex;
    gap: 0.4rem;
    margin-top: 0.5rem;
  }
  .vers {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  .ver-li {
    display: flex;
    align-items: baseline;
    gap: 0.6rem;
    padding: 0.3rem 0;
    border-top: 1px solid color-mix(in srgb, currentColor 8%, transparent);
    font-size: 0.85rem;
  }
  .ver-li code {
    font-size: 0.75rem;
    opacity: 0.7;
  }
  .ver-li.active {
    background: color-mix(in srgb, currentColor 6%, transparent);
  }
  .ver-msg {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .ver-meta {
    font-size: 0.72rem;
    opacity: 0.55;
    flex: none;
  }
  .ver-now {
    font-size: 0.72rem;
    opacity: 0.8;
    flex: none;
  }
</style>
