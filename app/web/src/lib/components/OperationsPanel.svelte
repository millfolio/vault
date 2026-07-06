<script lang="ts">
  // Operations — the single "what is the machine doing" view. Folds together what
  // used to be three places (the Vault → Operations history, the System → Backfill
  // panel, and the System info tab) into one page, top→bottom:
  //   Now       — the running job (index or backfill) + the queue behind it
  //   Controls  — global Pause + Priority (govern index AND backfill)
  //   History   — the durable operations log, failures surfaced
  //   System    — GPU / mem / disk / model (the data & log locations live in the
  //               sibling Logs sub-tab, rendered by the OperationsView wrapper)
  //   Backfill  — per-AI-tag backfill progress, a detail of the running/last backfill
  // Backed by /api/{operations,index/status,orchestrator/queue,backfill/*,gpu,model,system}.
  import { onMount, onDestroy } from "svelte";
  import { opLabel, fmtDur, fmtEta } from "$lib/format";

  let { demo = false }: { demo?: boolean } = $props();

  // Same-origin resolution as VaultPanel: an explicit ?api= wins; Vite dev (:5173)
  // has no backend → sample data; every other origin is served by millfolio-server.
  function apiBase(): string | null {
    if (typeof location === "undefined") return null;
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    if (location.port === "5173") return null;
    return "";
  }

  interface Operation {
    type: "index" | "reindex" | "backfill" | "demo" | string;
    started: number; // epoch seconds
    finished: number; // epoch seconds
    status: "done" | "error" | string;
    detail: string;
    files?: number;
    txns?: number;
    tagged?: number;
    pid?: number; // present on failures (dead worker pid) — surfaced in History
  }
  interface IndexStatus {
    state: "idle" | "indexing" | "done" | "error";
    detail: string;
    current?: number; // present only during the per-file embedding phase ([n/M])
    total?: number;
  }
  interface QueueItem {
    id: number;
    kind: string; // index | index-prepare | finalize | backfill
    payload: string; // already shortened server-side (basename / "N files")
    prio: number;
    state: string; // pending | running
    pid: number; // running worker pid (0 while pending)
    startedTs: number; // epoch seconds (0 while pending)
  }
  interface PerTag {
    tag: string;
    question: string;
    total: number;
    evaluated: number;
    pending: number;
    yes: number;
    ready: boolean;
  }
  interface BackfillStatus {
    status: string;
    paused_until: number;
    priority?: string;
    perTag: PerTag[];
    pendingTotal: number;
  }
  interface DemoStatus {
    state: "idle" | "downloading" | "indexing" | "done" | "error" | string;
    detail: string;
    progress?: number; // 0..100 while downloading (-1/absent → indeterminate)
    bytesDone?: number;
    bytesTotal?: number;
    present?: boolean;
  }
  interface Gpu {
    util: number;
    mem: number;
    disk: number;
  }

  const MOCK_OPS: Operation[] = [
    { type: "backfill", started: 1783200000, finished: 1783200019, status: "done", detail: "AI-tag backfill complete", tagged: 42 },
    { type: "reindex", started: 1783100000, finished: 1783100126, status: "done", detail: "Indexed 128 chunks across 6 files", files: 6, txns: 444 },
    { type: "index", started: 1783000000, finished: 1782999940, status: "error", detail: "embedding engine not reachable (503)" },
  ];

  let ops = $state<Operation[] | null>(null);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let mock = $state(false);
  let idxStatus = $state<IndexStatus | null>(null);
  let demoImport = $state<DemoStatus | null>(null);
  let queue = $state<QueueItem[]>([]);
  let bk = $state<BackfillStatus | null>(null);
  let gpu = $state<Gpu | null>(null);
  let model = $state("");
  let now = $state(Math.floor(Date.now() / 1000));

  // ── Frontier-model API key (real install only) ──────────────────────────────
  // Native `.app` users who never set ANTHROPIC_API_KEY can paste it here; codegen
  // reads it on the next question with no restart. The server NEVER returns the full
  // key — only whether one is set + a masked "…last4" hint. We never store it in the
  // browser: it's POSTed and forgotten.
  let apiKeySet = $state(false);
  let apiKeyHint = $state("");
  let apiKeyInput = $state("");
  let apiKeyBusy = $state(false);
  let apiKeyMsg = $state("");
  let apiKeyErr = $state("");

  async function loadApiKey() {
    const base = apiBase();
    if (base === null || demo) return;
    try {
      const r = await fetch(`${base}/api/settings/apikey`);
      if (!r.ok) return; // older server → block simply stays hidden
      const d = await r.json();
      apiKeySet = !!d.set;
      apiKeyHint = typeof d.hint === "string" ? d.hint : "";
    } catch {
      /* transient — the block just shows the unset state */
    }
  }

  async function saveApiKey() {
    const base = apiBase();
    if (base === null || demo) return;
    apiKeyMsg = "";
    apiKeyErr = "";
    const key = apiKeyInput.trim();
    if (!key) {
      apiKeyErr = "Paste your Anthropic API key first.";
      return;
    }
    apiKeyBusy = true;
    try {
      const r = await fetch(`${base}/api/settings/apikey`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ key }),
      });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) {
        apiKeyErr = d.error ?? `couldn't save (HTTP ${r.status})`;
        return;
      }
      apiKeySet = !!d.set;
      apiKeyHint = typeof d.hint === "string" ? d.hint : "";
      apiKeyInput = ""; // never keep the raw key around in the browser
      apiKeyMsg = "Saved — your next question will use it.";
    } catch (e) {
      apiKeyErr = e instanceof Error ? e.message : "couldn't save the key";
    } finally {
      apiKeyBusy = false;
    }
  }

  async function clearApiKey() {
    const base = apiBase();
    if (base === null || demo) return;
    apiKeyMsg = "";
    apiKeyErr = "";
    apiKeyBusy = true;
    try {
      const r = await fetch(`${base}/api/settings/apikey`, { method: "DELETE" });
      const d = await r.json().catch(() => ({}));
      apiKeySet = !!d.set;
      apiKeyHint = typeof d.hint === "string" ? d.hint : "";
      apiKeyInput = "";
      apiKeyMsg = "Cleared.";
    } catch (e) {
      apiKeyErr = e instanceof Error ? e.message : "couldn't clear the key";
    } finally {
      apiKeyBusy = false;
    }
  }

  // opLabel + fmtDur + fmtEta live in $lib/format (pure + unit-tested).

  function fmtWhen(epoch: number): string {
    if (!epoch || Number.isNaN(epoch)) return "—";
    return new Date(epoch * 1000).toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
  }

  // Elapsed since an epoch, as `5s` / `2m 06s` (reuses fmtDur's formatting + guard).
  function fmtElapsed(startedTs: number): string {
    if (!startedTs || startedTs <= 0) return "";
    return fmtDur(startedTs, now);
  }

  // A friendly label for a work-item kind (server kinds → UI words).
  function kindLabel(kind: string): string {
    if (kind === "index") return "Index";
    if (kind === "index-prepare") return "Prepare";
    if (kind === "finalize") return "Finalize";
    if (kind === "backfill") return "Backfill";
    return kind;
  }

  async function load() {
    loading = true;
    error = null;
    const base = apiBase();
    if (base === null) {
      ops = MOCK_OPS;
      mock = true;
      loading = false;
      return;
    }
    // The history read can hang while an index holds the config dir busy; cap it at
    // 8s so a stuck request degrades to a small "couldn't load history" line rather
    // than an infinite spinner (the running-job row renders independently above).
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 8000);
    try {
      const res = await fetch(`${base}/api/operations`, {
        headers: { accept: "application/json" },
        signal: ctrl.signal,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      ops = ((await res.json()).operations ?? []) as Operation[];
      mock = false;
    } catch (e) {
      error = ctrl.signal.aborted
        ? "timed out"
        : e instanceof SyntaxError
          ? "the server response was unreadable"
          : e instanceof Error
            ? e.message
            : String(e);
    } finally {
      clearTimeout(timer);
      loading = false;
    }
  }

  // Poll the live machine state: the running index job, the work queue behind it, the
  // backfill status (drives Controls + the Backfill detail), and GPU/mem/disk. When an
  // index run settles, refresh the history so the new record shows up.
  async function pollStatus() {
    const base = apiBase();
    if (base === null) return;
    const prev = idxStatus?.state;
    try {
      const d = (await fetch(`${base}/api/index/status`).then((r) => (r.ok ? r.json() : null))) as IndexStatus | null;
      if (d) {
        idxStatus = d;
        if (prev === "indexing" && d.state !== "indexing") await load();
      }
    } catch {
      /* transient — keep polling */
    }
    if (demo) return; // the demo has no queue/backfill/GPU story
    // The onboarding sample-data import (download → index) is its own tracked job,
    // separate from the orchestrator index queue; surface it as a live "Now" row.
    try {
      const prevDemo = demoImport?.state;
      const dd = (await fetch(`${base}/api/demo/status`).then((r) => (r.ok ? r.json() : null))) as DemoStatus | null;
      if (dd) {
        demoImport = dd;
        const wasActive = prevDemo === "downloading" || prevDemo === "indexing";
        const stillActive = dd.state === "downloading" || dd.state === "indexing";
        if (wasActive && !stillActive) await load(); // settled → fold into History
      }
    } catch {
      /* transient — keep polling */
    }
    try {
      const q = await fetch(`${base}/api/orchestrator/queue`).then((r) => (r.ok ? r.json() : null));
      if (q && Array.isArray(q.items)) queue = q.items as QueueItem[];
    } catch {}
    try {
      const s = await fetch(`${base}/api/backfill/status`).then((r) => (r.ok ? r.json() : null));
      if (s) {
        bk = s as BackfillStatus;
        noteProgress(bk.pendingTotal);
      }
    } catch {}
    try {
      const g = await fetch(`${base}/api/gpu`).then((r) => (r.ok ? r.json() : null));
      if (g && typeof g.util === "number") gpu = g as Gpu;
    } catch {}
  }

  // ── Controls: global pause + priority (orchestrator-wide) ───────────────────
  async function pause(seconds: number) {
    const base = apiBase();
    if (base === null) return;
    const r = await fetch(`${base}/api/orchestrator/pause`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ seconds }),
    });
    if (r.ok) bk = (await r.json()).status as BackfillStatus;
  }
  async function resume() {
    const base = apiBase();
    if (base === null) return;
    stop = false;
    const r = await fetch(`${base}/api/orchestrator/resume`, { method: "POST" });
    if (r.ok) bk = (await r.json()).status as BackfillStatus;
  }
  async function setPriority(p: string) {
    const base = apiBase();
    if (base === null) return;
    lastSample = null;
    etaSeconds = null;
    const r = await fetch(`${base}/api/orchestrator/priority`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ priority: p }),
    });
    if (r.ok) bk = (await r.json()).status as BackfillStatus;
  }

  // ── Backfill drain + ETA (a detail action on the running/last backfill) ─────
  let etaSeconds = $state<number | null>(null);
  let lastSample: { pending: number; t: number } | null = null;
  function noteProgress(pending: number) {
    const t = Date.now();
    if (lastSample && pending < lastSample.pending) {
      const dt = (t - lastSample.t) / 1000;
      if (dt > 0.5) {
        const rate = (lastSample.pending - pending) / dt; // rows/sec
        if (rate > 0) etaSeconds = Math.round(pending / rate);
      }
    }
    if (!lastSample || pending !== lastSample.pending) lastSample = { pending, t };
    if (pending <= 0) etaSeconds = 0;
  }
  let draining = $state(false);
  let stop = false;
  async function runDrain() {
    const base = apiBase();
    if (base === null || draining) return;
    draining = true;
    stop = false;
    let lastPending = Infinity;
    try {
      for (let i = 0; i < 1000; i++) {
        if (stop) break;
        const r = await fetch(`${base}/api/backfill/run`, { method: "POST" });
        if (!r.ok) break;
        const body = await r.json();
        bk = body.status as BackfillStatus;
        if (!bk) break;
        noteProgress(bk.pendingTotal);
        if (bk.pendingTotal <= 0) break; // drained
        if (bk.status === "paused") break; // paused → stop
        // Progress = pendingTotal DECREASING (a slice can advance the ledger while
        // changing 0 rows). Stop only when pending stops falling (engine down/stuck).
        if (bk.pendingTotal >= lastPending) break;
        lastPending = bk.pendingTotal;
      }
    } finally {
      draining = false;
    }
  }

  let poll: ReturnType<typeof setInterval> | undefined;
  let tick: ReturnType<typeof setInterval> | undefined;
  onMount(() => {
    load();
    if (!demo && apiBase() !== null) {
      // Model name (best-effort) for the System section.
      fetch(`${apiBase()}/api/model`)
        .then((r) => (r.ok ? r.json() : null))
        .then((d) => { if (d && typeof d.model === "string") model = d.model; })
        .catch(() => {});
      loadApiKey(); // the Frontier-model key state (set/hint)
    }
    if (apiBase() !== null) {
      pollStatus();
      poll = setInterval(pollStatus, 2000);
      tick = setInterval(() => (now = Math.floor(Date.now() / 1000)), 1000);
    }
  });
  onDestroy(() => {
    stop = true;
    if (poll) clearInterval(poll);
    if (tick) clearInterval(tick);
  });

  // ── derived views ───────────────────────────────────────────────────────────
  const indexing = $derived(idxStatus?.state === "indexing");
  // The sample-data import is "live" while it's downloading or indexing. Its download
  // phase carries a determinate % (progress 0..100); the index phase is indeterminate.
  const demoImporting = $derived(
    demoImport?.state === "downloading" || demoImport?.state === "indexing",
  );
  const demoPct = $derived(
    demoImport?.state === "downloading" && typeof demoImport.progress === "number" && demoImport.progress >= 0
      ? demoImport.progress
      : -1,
  );
  const runningItem = $derived(queue.find((q) => q.state === "running") ?? null);
  const pendingItems = $derived(queue.filter((q) => q.state === "pending"));
  const pendingIndexFiles = $derived(pendingItems.filter((q) => q.kind === "index").length);
  // A backfill is "actively running" when the running work item is a backfill, OR the
  // user is draining now; "pending" when there are verdicts left but nothing running.
  const backfillRunning = $derived(draining || runningItem?.kind === "backfill");
  const pausedFor = $derived(bk && bk.paused_until > now ? bk.paused_until - now : 0);
  const pendingTotal = $derived(bk?.pendingTotal ?? 0);
  const pct = (t: PerTag) => (t.total === 0 ? 100 : Math.round((t.evaluated / t.total) * 100));
  const fmtSecs = (s: number) => (s >= 60 ? `${Math.round(s / 60)} min` : `${s}s`);
</script>

<section class="ops">
  {#if mock}
    <p class="banner">Sample data — open this from <code>mill start</code> (:10000) to see your machine's real activity.</p>
  {/if}

  <!-- ── Now: the running job + the queue behind it ─────────────────────────── -->
  <div class="block">
    <h3 class="bhead">Now</h3>
    {#if demoImporting}
      <div class="op live">
        <div class="line1">
          <span class="type">Sample data</span>
          <span class="badge running"><span class="spin" aria-hidden="true"></span>running</span>
          <span class="when">now</span>
        </div>
        {#if demoImport?.state === "downloading" && demoPct >= 0}
          <div class="progress">
            <div class="pbar" aria-hidden="true">
              <div class="pfill" style={`width:${demoPct}%`}></div>
            </div>
            <span class="pcount">Downloading — {demoPct}%</span>
          </div>
        {:else if demoImport?.state === "downloading"}
          <p class="detail">Downloading sample data…</p>
        {:else}
          <p class="detail">Indexing sample data (first run loads the embedding model)…</p>
        {/if}
      </div>
    {/if}
    {#if indexing || runningItem?.kind === "index" || runningItem?.kind === "index-prepare" || runningItem?.kind === "finalize"}
      <div class="op live">
        <div class="line1">
          <span class="type">Index</span>
          <span class="badge running"><span class="spin" aria-hidden="true"></span>running</span>
          {#if runningItem && runningItem.startedTs > 0}<span class="dur">{fmtElapsed(runningItem.startedTs)}</span>{/if}
          {#if runningItem && runningItem.pid > 0}<span class="pid">pid {runningItem.pid}</span>{/if}
          <span class="when">now</span>
        </div>
        {#if idxStatus?.total && idxStatus.total > 0}
          <div class="progress">
            <div class="pbar" aria-hidden="true">
              <div class="pfill" style={`width:${Math.min(100, ((idxStatus.current ?? 0) / idxStatus.total) * 100)}%`}></div>
            </div>
            <span class="pcount">{idxStatus.current ?? 0} of {idxStatus.total} files</span>
          </div>
        {:else if idxStatus?.detail}
          <p class="detail">{idxStatus.detail}</p>
        {/if}
      </div>
    {:else if backfillRunning}
      <div class="op live">
        <div class="line1">
          <span class="type">Backfill</span>
          <span class="badge running"><span class="spin" aria-hidden="true"></span>running</span>
          {#if runningItem && runningItem.startedTs > 0}<span class="dur">{fmtElapsed(runningItem.startedTs)}</span>{/if}
          {#if runningItem && runningItem.pid > 0}<span class="pid">pid {runningItem.pid}</span>{/if}
          <span class="when">now</span>
        </div>
        <p class="detail">
          {pendingTotal} transaction-verdict{pendingTotal === 1 ? "" : "s"} to compute
          {#if etaSeconds && etaSeconds > 0} · ~{fmtEta(etaSeconds)} left{/if}
        </p>
      </div>
    {:else if pendingTotal > 0}
      <div class="op">
        <div class="line1">
          <span class="type">Backfill</span>
          <span class="badge">pending</span>
          <span class="when">between slices</span>
        </div>
        <p class="detail">{pendingTotal} transaction-verdict{pendingTotal === 1 ? "" : "s"} left to compute.</p>
      </div>
    {:else if !demoImporting}
      <p class="idle muted">Nothing running — the machine is idle.</p>
    {/if}

    {#if pendingItems.length > 0}
      <div class="queue">
        <div class="qhead">
          {#if pendingIndexFiles > 0}
            {pendingIndexFiles} file{pendingIndexFiles === 1 ? "" : "s"} queued
          {:else}
            {pendingItems.length} item{pendingItems.length === 1 ? "" : "s"} queued
          {/if}
          <span class="qbehind">behind the running job</span>
        </div>
        <ul class="qlist">
          {#each pendingItems.slice(0, 6) as q (q.id)}
            <li class="qitem">
              <span class="qkind">{kindLabel(q.kind)}</span>
              <span class="qpayload">{q.payload}</span>
            </li>
          {/each}
          {#if pendingItems.length > 6}
            <li class="qitem more">+{pendingItems.length - 6} more…</li>
          {/if}
        </ul>
      </div>
    {/if}
  </div>

  <!-- ── Controls: global pause + priority (govern index AND backfill) ──────── -->
  {#if !demo}
    <div class="block">
      <h3 class="bhead">Controls</h3>
      <div class="controls">
        {#if pausedFor > 0}
          <span class="paused">All background work paused for {fmtSecs(pausedFor)}</span>
          <button type="button" class="btn" onclick={resume}>Resume</button>
        {:else}
          <button type="button" class="btn" onclick={() => pause(3600)}>Pause for 1 hr</button>
        {/if}
        <span class="prio">
          <span class="plabel">Priority</span>
          {#each ["high", "medium", "low"] as p}
            <button
              type="button"
              class="pbtn"
              class:active={(bk?.priority ?? "medium") === p}
              onclick={() => setPriority(p)}
            >{p}</button>
          {/each}
        </span>
      </div>
      <p class="chint">
        Pause halts indexing and AI-tag backfill (chat and ask always run). Low leaves
        the GPU mostly free (slower); high runs background work near back-to-back.
      </p>
    </div>
  {/if}

  <!-- ── History: the durable operations log, failures surfaced ─────────────── -->
  <div class="block">
    <h3 class="bhead">History</h3>
    <ul class="oplist">
      {#if loading && ops === null}
        <li class="loadingrow"><p class="muted">Loading history…</p></li>
      {:else if error}
        <li class="loadingrow"><p class="muted hint">Couldn't load history: {error}</p></li>
      {:else if ops && ops.length > 0}
        {#each ops as o, i (o.started + "-" + o.type + "-" + i)}
          <li class="op" class:failed={o.status === "error"}>
            <div class="line1">
              <span class="type">{opLabel(o.type)}</span>
              {#if o.status === "done"}
                <span class="badge ok">✓ done</span>
              {:else if o.status === "error"}
                <span class="badge err">✗ failed</span>
                {#if typeof o.pid === "number" && o.pid > 0}<span class="pid">pid {o.pid}</span>{/if}
              {:else}
                <span class="badge">{o.status}</span>
              {/if}
              <span class="dur">{fmtDur(o.started, o.finished)}</span>
              <span class="counts">
                {#if typeof o.files === "number"}<span class="ct">{o.files} file{o.files === 1 ? "" : "s"}</span>{/if}
                {#if typeof o.txns === "number"}<span class="ct">{o.txns.toLocaleString()} txns</span>{/if}
                {#if typeof o.tagged === "number"}<span class="ct">{o.tagged.toLocaleString()} tagged</span>{/if}
              </span>
              <span class="when">{fmtWhen(o.started)}</span>
            </div>
            {#if o.detail}
              <p class="detail" class:err={o.status === "error"}>{o.detail}</p>
            {/if}
          </li>
        {/each}
      {:else}
        <li class="empty">
          <p class="muted">No operations yet.</p>
          <p class="muted hint">Index a folder or run an AI-tag backfill and its runs will show up here.</p>
        </li>
      {/if}
    </ul>
  </div>

  <!-- ── Backfill: per-AI-tag progress (a detail of the running/last backfill) ─ -->
  {#if !demo && bk && bk.perTag.length > 0}
    <div class="block">
      <h3 class="bhead">Backfill detail</h3>
      <div class="mat">
        <div class="mhead">
          <span class="sub">
            {#if pendingTotal > 0}
              {pendingTotal} transaction-verdict{pendingTotal === 1 ? "" : "s"} to compute
              {#if etaSeconds && etaSeconds > 0} · ~{fmtEta(etaSeconds)} left{/if}
            {:else}
              all AI tags backfilled
            {/if}
          </span>
          {#if pausedFor === 0}
            <button
              type="button"
              class="btn primary sm"
              onclick={runDrain}
              disabled={draining || pendingTotal === 0}
            >{draining ? "Backfilling…" : "Backfill now"}</button>
          {/if}
        </div>
        <div class="bars">
          {#each bk.perTag as t}
            <div class="bar">
              <div class="btop">
                <span class="bname">{t.tag}</span>
                {#if t.ready}
                  <span class="tbadge ok">ready</span>
                {:else}
                  <span class="tbadge pend">pending</span>
                {/if}
                <span class="frac">{t.evaluated}/{t.total} · {pct(t)}%</span>
                <span class="yes">{t.yes} match{t.yes === 1 ? "" : "es"}</span>
              </div>
              <div class="track"><div class="fill" style="width:{pct(t)}%"></div></div>
            </div>
          {/each}
        </div>
      </div>
    </div>
  {/if}

  <!-- ── System: GPU / mem / disk / model (data & log locations → Logs sub-tab) ─ -->
  {#if !demo && (gpu || model)}
    <div class="block">
      <h3 class="bhead">System</h3>
      <div class="stats">
        {#if gpu}
          <div class="stat"><span class="slabel">GPU</span><span class="sval">{gpu.util}%</span></div>
          <div class="stat"><span class="slabel">Memory</span><span class="sval">{gpu.mem}%</span></div>
          <div class="stat"><span class="slabel">Disk</span><span class="sval">{gpu.disk}%</span></div>
        {/if}
        {#if model}
          <div class="stat wide"><span class="slabel">Model</span><span class="sval">{model}</span></div>
        {/if}
      </div>
    </div>
  {/if}

  <!-- ── Frontier model: the Anthropic API key codegen needs (real install only) ─ -->
  {#if !demo && !mock}
    <div class="block" id="apikey">
      <h3 class="bhead">Frontier model</h3>
      <p class="khint">
        Writing a vault program uses Anthropic's frontier model. Paste your API
        key so questions work without setting an environment variable. It's
        stored on this device only (owner-only file) and never leaves it except
        to Anthropic.
      </p>
      {#if apiKeySet}
        <p class="kstate">Key is set <span class="kmask">{apiKeyHint}</span></p>
      {:else}
        <p class="kstate kunset">No key set — vault questions can't run yet.</p>
      {/if}
      <div class="krow">
        <input
          class="kinput"
          type="password"
          autocomplete="off"
          placeholder="sk-ant-…"
          bind:value={apiKeyInput}
          disabled={apiKeyBusy}
          onkeydown={(e) => { if (e.key === "Enter") saveApiKey(); }}
        />
        <button class="kbtn" onclick={saveApiKey} disabled={apiKeyBusy || !apiKeyInput.trim()}>
          {apiKeySet ? "Replace" : "Save"}
        </button>
        {#if apiKeySet}
          <button class="kbtn ghost" onclick={clearApiKey} disabled={apiKeyBusy}>Clear</button>
        {/if}
      </div>
      {#if apiKeyErr}
        <p class="kmsg kerr">{apiKeyErr}</p>
      {:else if apiKeyMsg}
        <p class="kmsg kok">{apiKeyMsg}</p>
      {/if}
    </div>
  {/if}
</section>

<style>
  .ops {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    max-width: 820px;
    margin: 0 auto;
    width: 100%;
  }
  .block {
    margin-bottom: 22px;
  }
  .bhead {
    margin: 0 0 10px;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-dim);
  }
  .oplist,
  .qlist {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .op {
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--bg);
    padding: 10px 14px;
  }
  .op.live {
    border-color: var(--accent);
  }
  .op.failed {
    border-color: color-mix(in srgb, var(--err, #e5484d) 55%, var(--border));
  }
  .line1 {
    display: flex;
    align-items: baseline;
    flex-wrap: wrap;
    gap: 10px;
  }
  .type {
    font-weight: 600;
    font-size: 13px;
    color: var(--text);
  }
  .badge {
    font-size: 11.5px;
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }
  .badge.ok {
    color: var(--ok);
  }
  .badge.err {
    color: var(--err);
  }
  .badge.running {
    color: var(--accent);
  }
  .pid {
    font-size: 11px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .dur {
    font-size: 12px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .counts {
    display: inline-flex;
    gap: 10px;
    flex-wrap: wrap;
  }
  .counts .ct {
    font-size: 11.5px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .when {
    margin-left: auto;
    font-size: 11.5px;
    color: var(--text-dim);
  }
  .detail {
    margin: 6px 0 0;
    font-size: 12px;
    color: var(--text-dim);
    word-break: break-word;
  }
  .detail.err {
    color: var(--err);
  }
  .progress {
    margin: 8px 0 0;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .pbar {
    flex: 1 1 auto;
    height: 5px;
    border-radius: 3px;
    background: var(--surface-2);
    overflow: hidden;
  }
  .pfill {
    height: 100%;
    background: var(--accent);
    border-radius: 3px;
    transition: width 0.3s ease;
  }
  .pcount {
    flex: none;
    font-size: 11.5px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .idle {
    margin: 0;
    font-size: 13px;
  }
  /* ── queue behind the running job ────────────────────────────────────────── */
  .queue {
    margin-top: 10px;
    border: 1px dashed var(--border);
    border-radius: var(--radius);
    padding: 10px 12px;
  }
  .qhead {
    font-size: 12px;
    font-weight: 600;
    color: var(--text);
    margin-bottom: 6px;
  }
  .qbehind {
    font-weight: 400;
    color: var(--text-dim);
    margin-left: 4px;
  }
  .qitem {
    display: flex;
    align-items: baseline;
    gap: 8px;
    font-size: 12px;
  }
  .qkind {
    flex: none;
    min-width: 62px;
    color: var(--text-dim);
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-weight: 600;
  }
  .qpayload {
    color: var(--text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .qitem.more {
    color: var(--text-dim);
    font-style: italic;
  }
  /* ── controls ────────────────────────────────────────────────────────────── */
  .controls {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }
  .prio {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .plabel {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-dim);
    margin-right: 2px;
  }
  .pbtn {
    padding: 3px 12px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
    font: inherit;
    font-size: 12px;
    text-transform: capitalize;
  }
  .pbtn:hover {
    border-color: var(--accent);
  }
  .pbtn.active {
    background: var(--accent);
    border-color: var(--accent);
    color: #06101f;
    font-weight: 600;
  }
  .chint {
    margin: 8px 0 0;
    font-size: 11.5px;
    color: var(--text-dim);
  }
  .paused {
    font-size: 12px;
    color: var(--warn);
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
  .btn.sm {
    padding: 4px 10px;
    font-size: 12px;
  }
  .btn:disabled {
    opacity: 0.55;
    cursor: default;
  }
  /* ── backfill detail ─────────────────────────────────────────────────────── */
  .mat {
    background: var(--surface-2);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 14px 16px;
  }
  .mhead {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
  }
  .sub {
    font-size: 12px;
    color: var(--text-dim);
  }
  .mhead .btn {
    margin-left: auto;
  }
  .bars {
    display: flex;
    flex-direction: column;
    gap: 9px;
  }
  .btop {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    margin-bottom: 3px;
  }
  .bname {
    font-weight: 600;
  }
  .tbadge {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    border-radius: 999px;
    padding: 0 6px;
  }
  .tbadge.ok {
    color: var(--ok);
    border: 1px solid var(--ok);
  }
  .tbadge.pend {
    color: var(--warn);
    border: 1px solid var(--warn);
  }
  .frac {
    color: var(--text-dim);
  }
  .yes {
    margin-left: auto;
    color: var(--text-dim);
  }
  .track {
    height: 6px;
    background: var(--bg);
    border-radius: 999px;
    overflow: hidden;
  }
  .fill {
    height: 100%;
    background: var(--accent);
    border-radius: 999px;
    transition: width 0.3s ease;
  }
  /* ── system stats ────────────────────────────────────────────────────────── */
  .stats {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-bottom: 8px;
  }
  .stat {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 8px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--bg);
    min-width: 74px;
  }
  .stat.wide {
    flex: 1 1 auto;
    min-width: 160px;
  }
  .slabel {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-dim);
  }
  .sval {
    font-size: 14px;
    font-weight: 600;
    color: var(--text);
    font-variant-numeric: tabular-nums;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  /* ── Frontier-model API key ────────────────────────────────────────────────── */
  .khint {
    margin: 0 0 10px;
    font-size: 12px;
    color: var(--text-dim);
    line-height: 1.5;
    max-width: 62ch;
  }
  .kstate {
    margin: 0 0 8px;
    font-size: 13px;
    color: var(--text);
  }
  .kstate.kunset {
    color: var(--err, #e5484d);
  }
  .kmask {
    font-variant-numeric: tabular-nums;
    color: var(--text-dim);
  }
  .krow {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    align-items: center;
  }
  .kinput {
    flex: 1 1 240px;
    min-width: 180px;
    padding: 8px 10px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--bg);
    color: var(--text);
    font-size: 13px;
    font-family: inherit;
  }
  .kinput:focus {
    outline: none;
    border-color: var(--accent);
  }
  .kbtn {
    padding: 8px 14px;
    border: 1px solid var(--accent);
    border-radius: var(--radius);
    background: var(--accent);
    color: #fff;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
  }
  .kbtn.ghost {
    background: transparent;
    color: var(--text);
    border-color: var(--border);
  }
  .kbtn:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .kmsg {
    margin: 8px 0 0;
    font-size: 12px;
  }
  .kmsg.kerr {
    color: var(--err, #e5484d);
  }
  .kmsg.kok {
    color: var(--accent);
  }
  /* ── shared ──────────────────────────────────────────────────────────────── */
  .empty {
    padding: 20px 0;
  }
  .loadingrow {
    padding: 12px 2px;
  }
  .muted {
    color: var(--text-dim);
  }
  .hint {
    margin-top: 6px;
    font-size: 12px;
  }
  .banner {
    margin: 0 0 14px;
    padding: 8px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--surface-2);
    font-size: 12.5px;
    color: var(--text-dim);
  }
  .banner code {
    font-family: var(--mono);
  }
  .spin {
    flex: none;
    width: 11px;
    height: 11px;
    border: 2px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    display: inline-block;
    animation: opspin 0.8s linear infinite;
  }
  @keyframes opspin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
