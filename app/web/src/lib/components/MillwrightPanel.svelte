<script lang="ts">
  import { onMount } from "svelte";
  import ResultView from "./ResultView.svelte";
  import type { MillfolioClient, ResultSpec, ServerEvent } from "$lib/protocol";
  import {
    acceptSpec as demoAccept,
    activeSpec as demoActiveSpec,
    fnv1a64,
    loadDemoBoard,
    resetDemoBoard,
    revertTo as demoRevert,
    type DemoStored,
  } from "$lib/demoBoard";

  // Millwright — the versioned, user-owned dashboard (designs/MILLWRIGHT.md).
  // This component is TRUSTED CHROME: it is hand-written and interprets the
  // generated spec as data. The spec never carries markup or URLs (the server
  // lints that before a version is accepted); every string renders as text.

  let { client, demo = false, pageId = "" }: { client: MillfolioClient; demo?: boolean; pageId?: string } = $props();

  type Widget = { id: string; title: string; q?: string; w?: number; h?: number; program?: string };
  type Layout = { cols?: number; order?: string[] };
  type Page = { id: string; title: string; widgets: Widget[]; layout?: Layout };
  type Spec = {
    v: number;
    kind: string;
    widgets: Widget[];
    layout?: Layout;
    pages?: Page[];
  };
  type Snapshot = { ts: number; result: ResultSpec; preview?: boolean; program?: string };
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

  // In the DEMO the server is read-only, so edits live in THIS BROWSER: a
  // localStorage version chain seeded from the server's board (demoBoard.ts).
  // The chrome below routes every write through it when `demo` is set.
  let demoStore = $state<DemoStored | null>(null);
  function applyDemo(d: DemoStored) {
    demoStore = d;
    spec = demoActiveSpec(d) as Spec | null;
    active = d.active;
    results = d.results as Record<string, Snapshot>;
  }

  async function load() {
    loadError = "";
    try {
      const r = await fetch("/api/millwright");
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const d = await r.json();
      if (demo) {
        applyDemo(loadDemoBoard({ spec: d?.spec, results: d?.results ?? {} }));
        return;
      }
      spec = d?.spec ?? null;
      active = d?.active ?? "";
      results = d?.results ?? {};
    } catch (e) {
      loadError = String(e);
    }
  }
  onMount(async () => {
    await load();
    autoComputeExamples();
  });

  // First-install UX: widgets still showing the seeded EXAMPLE results compute
  // their real result automatically (same path as ↻) as soon as the vault has
  // any records — synthetic data on a real install is confusing. Empty vault →
  // keep the examples (all-zero widgets are worse onboarding). Once per page
  // load; the orchestrator serializes the runs server-side. Skipped in the
  // demo (its board is the hermetic localStorage chain).
  let autoComputed = false;
  async function autoComputeExamples() {
    if (demo || autoComputed || !spec) return;
    const previewIds = Object.keys(results).filter((id) => results[id]?.preview);
    if (!previewIds.length) return;
    try {
      const r = await fetch("/api/transactions", {
        headers: { accept: "application/json" },
      });
      if (!r.ok) return;
      const rows = ((await r.json()).transactions ?? []) as unknown[];
      if (!rows.length) return; // nothing indexed yet — keep the examples
    } catch {
      return;
    }
    autoComputed = true;
    for (const id of previewIds) refresh(id);
  }

  // The CONTAINER this panel renders: the root board, or one spec page (v2 §2).
  const container = $derived.by(() => {
    if (!spec) return null;
    if (!pageId) return { widgets: spec.widgets, layout: spec.layout, title: "Board" };
    const pg = spec.pages?.find((p) => p.id === pageId);
    return pg ? { widgets: pg.widgets, layout: pg.layout, title: pg.title } : null;
  });

  // Keep the top-level nav's page buttons fresh — +page.svelte listens.
  $effect(() => {
    if (spec)
      window.dispatchEvent(new CustomEvent("millwright-pages", { detail: spec.pages ?? [] }));
  });

  // Widgets in layout order (unknown/missing order entries fall back to spec order).
  const ordered = $derived.by(() => {
    if (!container) return [] as Widget[];
    const byId = new Map(container.widgets.map((w) => [w.id, w]));
    const out: Widget[] = [];
    for (const id of container.layout?.order ?? []) {
      const w = byId.get(id);
      if (w) {
        out.push(w);
        byId.delete(id);
      }
    }
    for (const w of container.widgets) if (byId.has(w.id)) out.push(w);
    return out;
  });
  const cols = $derived(Math.min(Math.max(container?.layout?.cols ?? 2, 1), 6));

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
    if (demo && demoStore) {
      try {
        applyDemo(demoAccept(demoStore, specDraft, "hand-edited spec", "you"));
        showSpec = false;
      } catch (e) {
        specError = e instanceof Error ? e.message : String(e);
      }
      return;
    }
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
    // × sits next to edit/refresh — deleting must not be a slip of the finger.
    if (!confirm(`Remove "${w.title}" from the board? The version history keeps it, but there is no undo button yet.`)) return;
    const next = mapContainer((c) => ({
      widgets: c.widgets.filter((x) => x.id !== w.id),
      layout: {
        ...(c.layout ?? {}),
        order: (c.layout?.order ?? []).filter((id) => id !== w.id),
      },
    }));
    if (!next) return;
    try {
      await acceptSpecEdit(next, `removed "${w.title}"`);
    } catch {}
  }
  async function openVersions() {
    showVersions = true;
    showSpec = false;
    if (demo && demoStore) {
      versions = [...demoStore.versions].reverse() as Version[];
      active = demoStore.active;
      return;
    }
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
  // ── inline per-tile editor (title + span; program on real installs) ──
  let editId = $state("");
  let editTitle = $state("");
  let editW = $state(1);
  let editH = $state(1);
  let editCode = $state("");
  let editCodeLoaded = $state(false);
  let editCodeDirty = $state(false);
  let editErr = $state("");
  let editBusy = $state(false);

  function openEdit(w: Widget) {
    editId = w.id;
    editTitle = w.title;
    editW = w.w ?? 1;
    editH = w.h ?? 1;
    editCode = "";
    editCodeLoaded = false;
    editCodeDirty = false;
    editErr = "";
  }
  async function loadEditCode() {
    if (editCodeLoaded || demo) return;
    try {
      const r = await fetch(`/api/millwright/program?id=${encodeURIComponent(editId)}`);
      const d = await r.json();
      if (r.ok && d?.program) {
        editCode = d.program;
        editCodeLoaded = true;
      } else {
        editErr = d?.error ?? "couldn't load the program";
      }
    } catch (e) {
      editErr = String(e);
    }
  }
  // Apply `fn` to THIS panel's container (root board or the page) and return
  // the whole edited spec — every mutation below goes through here so pages
  // and the board share one code path.
  function mapContainer(fn: (c: { widgets: Widget[]; layout?: Layout }) => { widgets: Widget[]; layout?: Layout }): Spec | null {
    if (!spec) return null;
    if (!pageId) {
      const c = fn({ widgets: spec.widgets, layout: spec.layout });
      return { ...spec, widgets: c.widgets, layout: c.layout };
    }
    return {
      ...spec,
      pages: (spec.pages ?? []).map((p) => {
        if (p.id !== pageId) return p;
        const c = fn({ widgets: p.widgets, layout: p.layout });
        return { ...p, widgets: c.widgets, layout: c.layout };
      }),
    };
  }
  function specWithTileEdits(): Spec | null {
    return mapContainer((c) => ({
      ...c,
      widgets: c.widgets.map((x) =>
        x.id === editId
          ? { ...x, title: editTitle.trim() || x.title, w: editW, h: editH }
          : x,
      ),
    }));
  }
  async function acceptSpecEdit(next: Spec, msg: string) {
    if (demo && demoStore) {
      applyDemo(demoAccept(demoStore, JSON.stringify(next), msg, "you"));
      return;
    }
    const r = await fetch("/api/millwright/spec", {
      method: "POST",
      body: JSON.stringify({ spec: next, message: msg }),
    });
    const d = await r.json();
    if (!r.ok || d?.error) throw new Error(d?.error ?? `HTTP ${r.status}`);
    await load();
  }

  // "Save a program as a button": move a widget off the board into a NEW page
  // rendered as a top-level nav entry — the v2 §2 on-ramp. One spec version.
  let promoteErr = $state("");
  async function promoteToPage(w: Widget) {
    if (!spec) return;
    promoteErr = "";
    if ((spec.pages?.length ?? 0) >= 5) {
      promoteErr = "at most 5 pages — dissolve one first";
      return;
    }
    const pid = "p-" + fnv1a64(w.id + ":" + Date.now()).slice(0, 8);
    const next: Spec = {
      ...spec,
      widgets: spec.widgets.filter((x) => x.id !== w.id),
      layout: {
        ...(spec.layout ?? {}),
        order: (spec.layout?.order ?? []).filter((id) => id !== w.id),
      },
      pages: [
        ...(spec.pages ?? []),
        { id: pid, title: w.title, widgets: [{ ...w, w: 2 }], layout: { cols: 2, order: [w.id] } },
      ],
    };
    try {
      await acceptSpecEdit(next, `made "${w.title}" a page`);
    } catch (e) {
      promoteErr = e instanceof Error ? e.message : String(e);
    }
  }

  // The inverse: the page's widgets return to the board, the nav entry goes.
  async function dissolvePage() {
    if (!spec || !pageId) return;
    const pg = spec.pages?.find((p) => p.id === pageId);
    if (!pg) return;
    const next: Spec = {
      ...spec,
      widgets: [...spec.widgets, ...pg.widgets],
      layout: {
        ...(spec.layout ?? {}),
        order: [...(spec.layout?.order ?? []), ...pg.widgets.map((w) => w.id)],
      },
      pages: (spec.pages ?? []).filter((p) => p.id !== pageId),
    };
    try {
      await acceptSpecEdit(next, `dissolved page "${pg.title}"`);
      location.href = "/board"; // the page's URL just stopped existing
    } catch (e) {
      promoteErr = e instanceof Error ? e.message : String(e);
    }
  }
  async function saveEdit(andRun = false) {
    if (!spec || editBusy) return;
    editBusy = true;
    editErr = "";
    try {
      const before = container?.widgets.find((x) => x.id === editId);
      const dims =
        !!before &&
        (before.title !== editTitle.trim() || (before.w ?? 1) !== editW || (before.h ?? 1) !== editH);
      // 1. the view-plane part (title/span) — a spec version
      if (dims) {
        const next = specWithTileEdits();
        if (next) await acceptSpecEdit(next, `edited "${editTitle.trim() || before!.title}"`);
      }
      // 2. the data-plane part (the program) — content-addressed snapshot +
      //    rebinding version; server-only (the demo can't run programs anyway)
      if (!demo && editCodeDirty && editCode.trim()) {
        const r = await fetch("/api/millwright/program", {
          method: "POST",
          body: JSON.stringify({ id: editId, code: editCode }),
        });
        const d = await r.json();
        if (!r.ok || d?.error) throw new Error(d?.error ?? `HTTP ${r.status}`);
      }
      const ranId = editId;
      editId = "";
      await load();
      if (andRun && !demo) await refresh(ranId);
    } catch (e) {
      editErr = e instanceof Error ? e.message : String(e);
    } finally {
      editBusy = false;
    }
  }

  // Demo only: drop every local edit, back to the server's board.
  async function resetDemo() {
    resetDemoBoard();
    demoStore = null;
    await load();
  }

  // ── model-assisted edit: the instruction goes to the frontier via the
  // server (enclave transport); the reply is linted by the same validator
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
    if (demo && demoStore) {
      applyDemo(demoRevert(demoStore, hash));
      await openVersions();
      return;
    }
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
    <h2>{container?.title ?? "Board"}</h2>
    <div class="board-actions">
      {#if pageId && container}
        <button type="button" class="chrome-btn" title="Move this page's widgets back to the Board and drop the nav button" onclick={dissolvePage}>dissolve page</button>
      {/if}
      {#if demo}
        <span class="demo-note" title="Demo edits live in THIS browser's localStorage — the shared demo is untouched">edits stay in your browser</span>
        <button type="button" class="chrome-btn" title="Drop your local edits — back to the shared demo board" onclick={resetDemo}>reset</button>
      {/if}
      <button type="button" class="chrome-btn" class:on={showSpec} onclick={() => (showSpec ? (showSpec = false) : openSpec())} title="See and edit the spec this board is made of">spec</button>
      <button type="button" class="chrome-btn" class:on={showVersions} onclick={() => (showVersions ? (showVersions = false) : openVersions())} title="Every version of this board — diff and revert">history</button>
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

  {#if promoteErr}<p class="board-err">{promoteErr}</p>{/if}
  {#if loadError}
    <p class="board-err">Couldn't load the board: {loadError}</p>
  {:else if pageId && !container}
    <p class="board-empty">This page no longer exists — it may have been dissolved or reverted away. Head back to the <a href="/board">Board</a>.</p>
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
              {#if w.program && results[w.id]?.program && results[w.id].program !== w.program}
                <span class="stale-badge" title="The program was edited after this result was computed — ↻ to recompute">program changed</span>
              {/if}
              <span class="stamp">{asOf(w.id)}</span>
              <button type="button" class="tool" title="Edit this widget — title, size{demo ? '' : ', and its program'}" onclick={() => (editId === w.id ? (editId = "") : openEdit(w))}>✎</button>
              {#if !demo}
                <button type="button" class="tool" disabled={refreshing[w.id]} title="Re-run this widget's saved program over your current vault — no model call" onclick={() => refresh(w.id)}>{refreshing[w.id] ? "…" : "↻"}</button>
              {/if}
              <button type="button" class="tool" title="Remove from the board (the version history keeps it)" onclick={() => removeWidget(w)}>×</button>
            </div>
          </header>
          {#if editId === w.id}
            <div class="tile-edit">
              <div class="te-row">
                <label class="te-lab">title <input class="te-in" type="text" bind:value={editTitle} /></label>
                <label class="te-lab">w <input class="te-num" type="number" min="1" max="6" bind:value={editW} /></label>
                <label class="te-lab">h <input class="te-num" type="number" min="1" max="6" bind:value={editH} /></label>
              </div>
              {#if !demo}
                <details class="te-code" ontoggle={(e) => (e.currentTarget as HTMLDetailsElement).open && loadEditCode()}>
                  <summary>program{editCodeDirty ? " (edited)" : ""}</summary>
                  <p class="te-hint">The saved Mojo program this tile runs. Edits become a new snapshot on the version chain (revert undoes them); “save &amp; run” recomputes — compile errors stream back like any run.</p>
                  <textarea class="te-src" rows={14} spellcheck="false" bind:value={editCode} oninput={() => (editCodeDirty = true)} disabled={!editCodeLoaded}></textarea>
                </details>
              {/if}
              {#if editErr}<p class="board-err">{editErr}</p>{/if}
              <div class="te-actions">
                <button type="button" class="chrome-btn" disabled={editBusy} onclick={() => saveEdit(false)}>save</button>
                {#if !pageId}
                  <button type="button" class="chrome-btn" disabled={editBusy} title="Move this widget to its own page — a new button in the top nav" onclick={() => promoteToPage(w)}>make page</button>
                {/if}
                {#if !demo}
                  <button type="button" class="chrome-btn" disabled={editBusy} onclick={() => saveEdit(true)}>save &amp; run</button>
                {/if}
                <button type="button" class="chrome-btn" disabled={editBusy} onclick={() => (editId = "")}>cancel</button>
              </div>
            </div>
          {/if}
          <svelte:boundary>
            {#if results[w.id]?.result}
              <ResultView result={results[w.id].result} />
              {#if results[w.id]?.preview}
                <p class="example-note">
                  These numbers are synthetic examples, not from your files.
                  Once your documents are in the Vault this widget computes
                  from your own records —
                  <a href="https://millfolio.app/docs" target="_blank" rel="noopener"
                    >learn how to add your data →</a
                  >
                </p>
              {/if}
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
  .demo-note {
    font-size: 0.72rem;
    opacity: 0.55;
    align-self: center;
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
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  /* Shrink priority (same invariant as the records row): the BUTTONS are the
     content of this strip and never shrink; the stamp is decoration and
     ellipsizes first — otherwise a long stamp ("example data — ↻ …") pushes
     ✎/↻/× past the tile edge on phones and the board looks uneditable. */
  .tile-tools {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    flex: 0 1 auto;
    min-width: 0;
  }
  .example-note {
    margin: 8px 0 0;
    font-size: 12px;
    color: var(--text-dim);
    border-top: 1px dashed var(--border);
    padding-top: 6px;
  }
  .example-note a {
    color: inherit;
    text-decoration: underline dotted;
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
  .stale-badge {
    font-size: 0.62rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: #b8860b;
    border: 1px solid color-mix(in srgb, #b8860b 45%, transparent);
    border-radius: 0.3rem;
    padding: 0 0.3rem;
  }
  .tile-edit {
    border-top: 1px dashed color-mix(in srgb, currentColor 15%, transparent);
    margin: 0.4rem 0 0.5rem;
    padding-top: 0.5rem;
  }
  .te-row {
    display: flex;
    gap: 0.6rem;
    align-items: center;
    flex-wrap: wrap;
  }
  .te-lab {
    font-size: 0.75rem;
    opacity: 0.8;
    display: inline-flex;
    gap: 0.3rem;
    align-items: center;
  }
  .te-in {
    font: inherit;
    font-size: 0.82rem;
    padding: 0.15rem 0.4rem;
    border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
    border-radius: 0.35rem;
    background: transparent;
    color: inherit;
    min-width: 12rem;
  }
  .te-num {
    width: 3rem;
    font: inherit;
    font-size: 0.82rem;
    padding: 0.15rem 0.3rem;
    border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
    border-radius: 0.35rem;
    background: transparent;
    color: inherit;
  }
  .te-code {
    margin-top: 0.4rem;
    font-size: 0.78rem;
  }
  .te-code summary {
    cursor: pointer;
    opacity: 0.75;
  }
  .te-hint {
    font-size: 0.72rem;
    opacity: 0.6;
    margin: 0.25rem 0;
  }
  .te-src {
    width: 100%;
    font-family: ui-monospace, monospace;
    font-size: 0.75rem;
    border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
    border-radius: 0.4rem;
    background: transparent;
    color: inherit;
    padding: 0.45rem;
    box-sizing: border-box;
  }
  .te-actions {
    display: flex;
    gap: 0.4rem;
    margin-top: 0.45rem;
  }
  .stamp {
    font-size: 0.72rem;
    opacity: 0.55;
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
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
    flex: none;
  }
  /* Touch devices: the glyph buttons need real tap targets. */
  @media (pointer: coarse) {
    .tool {
      font-size: 1rem;
      padding: 0.2rem 0.4rem;
      opacity: 0.8;
    }
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
