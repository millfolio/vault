<script lang="ts">
  import { onMount } from "svelte";
  import { page } from "$app/state";
  import ChatPanel from "$lib/components/ChatPanel.svelte";
  import VaultPanel from "$lib/components/VaultPanel.svelte";
  import StatsPanel from "$lib/components/StatsPanel.svelte";
  import OperationsView from "$lib/components/OperationsView.svelte";
  import DisclaimerNotice from "$lib/components/DisclaimerNotice.svelte";
  import { createMockClient } from "$lib/client";
  import MillwrightPanel from "$lib/components/MillwrightPanel.svelte";
  import { createWsClient } from "$lib/wsClient";
  import { fmtEta, shortId } from "$lib/format";
  import type { ServerEvent, Session, MillfolioClient, StepState, ResultSpec } from "$lib/protocol";

  // One inline timeline: chat bubbles + the workflow events (status/debug/approval)
  // rendered in place, instead of a separate workflow pane.
  type ChatItem =
    | { kind: "user" | "assistant"; id: string; text: string; source?: string; sourceAlias?: string; result?: ResultSpec }
    | { kind: "status"; id: string; stepId: string; label: string; state: StepState; detail?: string }
    | { kind: "debug"; id: string; title: string; body: string; language?: string }
    | { kind: "tags"; id: string; tags: string }
    | { kind: "tag-proposal"; id: string; name: string; ml?: boolean; keywords?: string; prompt?: string }
    | {
        kind: "approval";
        id: string;
        stepId: string;
        title: string;
        body: string;
        language?: string;
        resolved?: "approved" | "rejected";
      };

  // Transport selection:
  //  - explicit ?server=ws://… wins (any host/port);
  //  - else when served locally by millfolio-server (:10000), open the WS on the
  //    SAME origin (one port now serves HTTP + WS; flare upgrades the request);
  //  - else (e.g. `npm run dev` on :5173) fall back to the in-browser mock.
  function pickClient(): MillfolioClient {
    if (typeof location === "undefined") return createMockClient();
    const explicit = new URLSearchParams(location.search).get("server");
    if (explicit) return createWsClient(explicit);
    // The Vite dev server (`npm run dev`, :5173) has no backend → in-browser mock.
    // EVERY other origin is the app served BY millfolio-server and is same-origin
    // with the WS endpoint — whether that's http://localhost:10000 OR an https
    // Tailscale/reverse-proxy host (port 443, MagicDNS). Keying off port===10000
    // wrongly fell back to the mock over Tailscale, so we invert: real WS unless dev.
    if (location.port === "5173") return createMockClient();
    const scheme = location.protocol === "https:" ? "wss" : "ws";
    // Pass a live getter for the demo-access token (empty until the Turnstile gate is
    // solved; the WS ask frame includes it so the server can validate — demo only).
    return createWsClient(`${scheme}://${location.host}/chat`, () => demoToken);
  }
  const client = pickClient();

  // Demo mode: the public replay demo only answers the curated questions (the replay
  // cache is keyed on the exact prompt), so we restrict input to a dropdown of those.
  // Detected by the demo host or its :10010 port (the real app is :10000 / free-text).
  function detectDemo(): boolean {
    if (typeof location === "undefined") return false;
    if (new URLSearchParams(location.search).get("demo") === "1") return true;
    return location.hostname.endsWith("demo.millfolio.app") || location.port === "10010";
  }
  const isDemo = detectDemo();

  // Millwright pages (v2 §2): spec-defined boards rendered as ADDITIVE nav
  // entries after the built-in tabs (never instead of them), capped at 5.
  // MillwrightPanel broadcasts the fresh list after every board load/edit;
  // the initial fetch covers direct landings on non-board tabs.
  let mwPages = $state<{ id: string; title: string }[]>([]);
  function setMwPages(pages: unknown) {
    if (!Array.isArray(pages)) return;
    mwPages = pages
      .filter((p: any) => typeof p?.id === "string" && typeof p?.title === "string")
      .slice(0, 5)
      .map((p: any) => ({ id: p.id, title: p.title }));
  }
  $effect(() => {
    const onPages = (e: Event) => setMwPages((e as CustomEvent).detail);
    window.addEventListener("millwright-pages", onPages);
    (async () => {
      try {
        const r = await fetch("/api/millwright");
        const d = await r.json();
        if (isDemo) {
          const { loadDemoBoard, activeSpec } = await import("$lib/demoBoard");
          const store = loadDemoBoard({ spec: d?.spec, results: d?.results ?? {} });
          setMwPages((activeSpec(store) as any)?.pages);
        } else {
          setMwPages(d?.spec?.pages);
        }
      } catch {} // board unreachable — nav just shows the built-ins
    })();
    return () => window.removeEventListener("millwright-pages", onPages);
  });

  // The product name follows the domain it's served from: millfolio.* → "millfolio",
  // millfoil.* → "millfoil" — i.e. the registrable name, the second-to-last DNS label.
  // Falls back to "millfolio" for localhost / IPs / single-label hosts.
  function brandFromHost(): string {
    if (typeof location === "undefined") return "millfolio";
    const labels = location.hostname.split(".").filter(Boolean);
    const sld = labels.length >= 2 ? labels[labels.length - 2] : "";
    return /^[a-z]/i.test(sld) ? sld : "millfolio";
  }
  const brandName = brandFromHost();
  $effect(() => {
    // Title tracks the brand too (app.html ships a static fallback).
    document.title = brandName.charAt(0).toUpperCase() + brandName.slice(1);
  });

  let items = $state<ChatItem[]>([]);
  let busy = $state(false);
  let session: Session | undefined;
  // The active tab is driven by the URL ([[tab]] optional-param route): "/" → chat,
  // "/vault" → vault, "/operations" → operations. One component serves all tabs, so
  // switching is a same-route param change (no remount) — the chat survives.
  //
  // Operations now carries three sub-tabs (Operations | Stats | Logs). "/stats" and
  // "/system" are kept as aliases that land on the right Operations sub-tab so old
  // links + the status-bar chips don't break: "/stats" → the Stats sub-tab, "/system"
  // → the Operations sub-tab (the old System info now lives under Operations/Logs).
  // The public demo is the exception — it has no Operations tab, so "/stats" there
  // still opens the standalone StatsPanel top-level.
  const view = $derived<"chat" | "vault" | "stats" | "operations" | "tags" | "board">(
    page.params.tab === "vault"
      ? "vault"
      : page.params.tab === "tags"
        ? "tags"
        : page.params.tab === "board" || page.params.tab?.startsWith("p-")
          ? "board"
          : page.params.tab === "operations" || page.params.tab === "system"
            ? "operations"
            : page.params.tab === "stats"
              ? isDemo
                ? "stats"
                : "operations"
              : "chat",
  );
  // Which Operations sub-tab a URL lands on: "/stats" → stats, everything else
  // (/operations, /system) → the main Operations sub-tab. Used to re-key OperationsView
  // so a URL change into a different sub-tab remounts it with a fresh initial value.
  const opSub = $derived(page.params.tab === "stats" ? "stats" : "operations");
  // Run-queue position — shown as a floating bottom-right badge, not inline.
  let queueMsg = $state<string | null>(null);
  // The on-device model the server serves (bottom status bar). Empty under the
  // in-browser mock (:5173, no backend) — the bar just omits it then.
  let modelName = $state("");
  // On-device model CATALOG: every supported chat model, each flagged
  // downloaded/not. A downloaded model is selectable (Use → switch); a
  // not-downloaded one shows a Download action (→ background fetch + poll).
  let models = $state<{ id: string; label: string; gb?: number; downloaded?: boolean }[]>([]);
  let currentModel = $state("");
  // Total physical RAM (GB) reported by the server (/api/models). 0/undefined on an
  // older server or the in-browser mock (:5173, no backend) → the fit check is skipped
  // and no model is grayed out (fall back to the prior behavior).
  let memoryGb = $state(0);
  // Headroom (GB) reserved for macOS itself, the app-server + web app, and the engine's
  // KV-cache/activations on top of the raw weights — so a model whose weights alone
  // nearly fill RAM is (correctly) flagged won't-fit. `gb` is the bf16 DOWNLOAD size, a
  // conservative UPPER bound on the runtime footprint (the engine may quantize to int4),
  // which is fine for an "unlikely to fit" heuristic — it errs toward caution.
  const RESERVE_GB = 5;
  let switching = $state(false);
  let catalogOpen = $state(false);
  // The in-flight download (from /api/models/download/status): which model +
  // running|done|error + the latest progress line, plus a numeric progress 0–100
  // (-1/undefined = unknown → indeterminate spinner) and optional byte counts.
  let dl = $state<{
    model: string;
    state: string;
    detail: string;
    progress?: number;
    bytesDone?: number;
    bytesTotal?: number;
  } | null>(null);
  let dlTimer: ReturnType<typeof setTimeout> | undefined;
  // Build stamp: the app SHA with the build date stripped. When the server reports a
  // real release version (a `mill` install — not the demo's "<sha> · <date>" deploy
  // stamp, nor "dev"), append it: "<sha> · v0.4.39-rc.2".
  let serverVersion = $state("");
  const buildSha = (typeof __APP_VERSION__ !== "undefined" ? __APP_VERSION__ : "dev").split(" · ")[0];
  const buildLabel = $derived(
    serverVersion && serverVersion !== "dev" && !serverVersion.includes(buildSha)
      ? `${buildSha} · ${serverVersion}`
      : buildSha,
  );

  // Bottom-bar telemetry (real install only): AI-tag backfill progress + a rolling
  // 30-second GPU-utilization average. Both poll lightweight endpoints every 2s; the
  // 30s window is kept here so /api/gpu can stay a cheap, stateless instantaneous read.
  let gpuAvg = $state<number | null>(null);
  let memUsed = $state<number | null>(null); // system memory-used %, from /api/gpu
  let diskUsed = $state<number | null>(null); // disk-used % of the vault volume, from /api/gpu
  let bkPending = $state(0);
  let bkPriority = $state("");
  let bkEta = $state<number | null>(null);
  // Running-index summary for the corner chip (from /api/index/status): live while
  // an index job runs, showing `current/total` files once the embedding phase's
  // `[n/M]` counter appears. Cleared the moment the job goes idle/done/error.
  let idxRunning = $state(false);
  let idxCurrent = $state<number | null>(null);
  let idxTotal = $state<number | null>(null);
  const gpuRing: { t: number; v: number }[] = [];
  let bkLast: { pending: number; t: number } | null = null;

  async function pollTelemetry() {
    // GPU: one instantaneous sample → averaged over the last 30s (client-side ring).
    try {
      const r = await fetch("/api/gpu");
      if (r.ok) {
        const d = await r.json();
        if (typeof d.util === "number" && d.util >= 0) {
          const t = Date.now();
          gpuRing.push({ t, v: d.util });
          while (gpuRing.length && t - gpuRing[0].t > 30000) gpuRing.shift();
          gpuAvg = Math.round(gpuRing.reduce((s, x) => s + x.v, 0) / gpuRing.length);
        }
        // Memory-used % rides the same sample (instantaneous — it's stable enough
        // that a rolling average isn't worth it).
        if (typeof d.mem === "number" && d.mem >= 0) memUsed = d.mem;
        // Disk-used % of the volume holding the vault + weights (same instantaneous sample).
        if (typeof d.disk === "number" && d.disk >= 0) diskUsed = d.disk;
      }
    } catch {}
    // Backfill: pending count + priority + a live ETA measured from the drain rate
    // (mirrors the Backfill panel), so it reflects the current priority's throttle.
    try {
      const r = await fetch("/api/backfill/status");
      if (r.ok) {
        const d = await r.json();
        bkPending = d.pendingTotal ?? 0;
        bkPriority = d.priority ?? "";
        const t = Date.now();
        if (bkLast && bkPending < bkLast.pending) {
          const dt = (t - bkLast.t) / 1000;
          if (dt > 0.5) {
            const rate = (bkLast.pending - bkPending) / dt; // rows/sec
            if (rate > 0) bkEta = Math.round(bkPending / rate);
          }
        }
        if (!bkLast || bkPending !== bkLast.pending) bkLast = { pending: bkPending, t };
        if (bkPending <= 0) bkEta = 0;
      }
    } catch {}
    // Index: a live n/M summary while a folder-index job runs — cleared as soon as
    // it settles (idle/done/error), so the chip is a brief background-op indicator.
    try {
      const r = await fetch("/api/index/status");
      if (r.ok) {
        const d = await r.json();
        if (d && d.state === "indexing") {
          idxRunning = true;
          idxCurrent = typeof d.current === "number" ? d.current : null;
          idxTotal = typeof d.total === "number" ? d.total : null;
        } else {
          idxRunning = false;
          idxCurrent = null;
          idxTotal = null;
        }
      }
    } catch {}
  }

  // Intro disclaimer — ONLY the public demo shows it (it explains the replay/queue
  // caveats that don't apply to a real local install). Remembered per browser session
  // so a reload within the same tab doesn't nag, but every new visitor sees it once.
  const INTRO_KEY = "millfolio-demo-intro-dismissed";
  // The demo-access token is persisted per tab-session so a reload reuses it (it
  // outlives the in-memory value but the server still enforces a 30-min TTL). Kept
  // SEPARATE from INTRO_KEY: the info-intro is dismissed once, but the Turnstile
  // widget must reappear whenever we lack a valid token (e.g. after a reload/expiry).
  const DEMO_TOKEN_KEY = "millfolio-demo-token";
  let showIntro = $state(false);
  // Cloudflare Turnstile (demo bot gate). The server exposes a non-empty sitekey ONLY
  // when the gate is active; the intro modal then renders the widget, and "Got it" is
  // blocked until it's solved. On solve we POST the token to /api/demo/verify, which
  // (server-side) validates it with Cloudflare and mints `demoToken` — echoed on every
  // WS chat ask (server on_connect rejects a missing/invalid one). Empty sitekey → the
  // whole gate is a no-op (real product / local dev).
  let turnstileSitekey = $state("");
  let turnstileToken = $state(""); // the widget's response token (once solved)
  let demoToken = $state(""); // our minted demo-access token (post-verify)
  let turnstileError = $state("");
  let verifying = $state(false);
  let turnstileEl = $state<HTMLDivElement | undefined>(undefined);
  let turnstileWidgetId: string | undefined;
  // Outside the demo: true when the on-device vault has nothing indexed yet, so we can
  // prompt the user to run `mill index` instead of dropping them into an empty chat.
  let vaultEmpty = $state(false);
  // First-run onboarding: a new user with an empty vault can fetch + index a hosted
  // sample vault (POST /api/demo/download, polled via /api/demo/status) so they can try
  // millfolio without pointing it at their own folder. `demoImport` mirrors the job
  // state (downloading|indexing|done|error); `demoReady` unlocks the suggested chips.
  let demoImport = $state<{
    state: string;
    detail: string;
    progress?: number; // 0..100 (download %, then the indexing % of files)
    bytesDone?: number;
    bytesTotal?: number;
    current?: number; // indexing phase: files done…
    total?: number; //  …of this many (the demo import mirrors the orchestrator)
  } | null>(null);
  let demoReady = $state(false);
  let demoImportTimer: ReturnType<typeof setTimeout> | undefined;
  // Suggested first questions — tuned for the sample data, dashboard question first.
  const DEMO_QUESTIONS = [
    "Build me a dashboard with spending by merchant for the last 3 months",
    "How much did I spend on groceries?",
    "Show my spending by month",
    "What was my biggest transaction?",
  ];
  // The onboarding banner shows only in a real install's empty vault, on the Chat tab,
  // and only until the first question lands (any chat activity → back to normal chat).
  const showOnboarding = $derived(
    !isDemo && vaultEmpty && view === "chat" && items.length === 0,
  );
  async function startDemoImport() {
    if (demoImport && (demoImport.state === "downloading" || demoImport.state === "indexing")) return;
    demoImport = { state: "downloading", detail: "Starting…" };
    try {
      const r = await fetch("/api/demo/download", { method: "POST" });
      if (!r.ok) {
        const e = await r.json().catch(() => ({}));
        demoImport = { state: "error", detail: e.error ?? "could not start" };
        return;
      }
      const d = await r.json().catch(() => ({}));
      if (d.state === "done") { onDemoDone(); return; }
      pollDemoImport();
    } catch {
      demoImport = { state: "error", detail: "could not start" };
    }
  }
  function pollDemoImport() {
    clearTimeout(demoImportTimer);
    demoImportTimer = setTimeout(async () => {
      try {
        const d = await fetch("/api/demo/status").then((r) => (r.ok ? r.json() : null));
        if (d) {
          demoImport = {
            state: d.state,
            detail: d.detail ?? "",
            progress: typeof d.progress === "number" ? d.progress : undefined,
            bytesDone: typeof d.bytesDone === "number" ? d.bytesDone : undefined,
            bytesTotal: typeof d.bytesTotal === "number" ? d.bytesTotal : undefined,
            current: typeof d.current === "number" ? d.current : undefined,
            total: typeof d.total === "number" ? d.total : undefined,
          };
          if (d.state === "done") { onDemoDone(); return; }
          if (d.state === "error") return; // leave the error visible with a Retry
        }
      } catch {}
      pollDemoImport();
    }, 1500);
  }
  function onDemoDone() {
    demoImport = { state: "done", detail: "" };
    demoReady = true; // the sample docs are indexed → the suggested chips go live
  }
  // Ask one of the suggested questions. send() pushes a chat item, which flips
  // showOnboarding off (items.length > 0), returning to the normal chat view.
  function askSuggested(q: string) {
    vaultEmpty = false;
    send(q);
  }
  onMount(() => {
    if (isDemo) {
      try {
        demoToken = sessionStorage.getItem(DEMO_TOKEN_KEY) || "";
        showIntro = sessionStorage.getItem(INTRO_KEY) !== "1";
      } catch {
        showIntro = true; // sessionStorage unavailable (private mode etc.) — still show it
      }
    } else {
      // Real install: is anything indexed? An empty/unindexed vault → show the
      // "run mill index" notice rather than an empty, answer-less chat.
      fetch("/api/vault", { headers: { accept: "application/json" } })
        .then((r) => (r.ok ? r.json() : null))
        .then((d) => { if (d) vaultEmpty = !d.indexed || (d.indexedFileCount ?? 0) === 0; })
        .catch(() => {});
      // Resume a sample-data import that's still running (or already finished) — e.g.
      // the page was reloaded mid-import — so the onboarding banner reflects it.
      fetch("/api/demo/status")
        .then((r) => (r.ok ? r.json() : null))
        .then((d) => {
          if (!d) return;
          if (d.state === "downloading" || d.state === "indexing") {
            demoImport = {
              state: d.state,
              detail: d.detail ?? "",
              progress: typeof d.progress === "number" ? d.progress : undefined,
              bytesDone: typeof d.bytesDone === "number" ? d.bytesDone : undefined,
              bytesTotal: typeof d.bytesTotal === "number" ? d.bytesTotal : undefined,
              current: typeof d.current === "number" ? d.current : undefined,
              total: typeof d.total === "number" ? d.total : undefined,
            };
            pollDemoImport();
          } else if (d.state === "done" && d.present) {
            onDemoDone();
          }
        })
        .catch(() => {});
    }
    // Ask the server which model it's serving (best-effort; mock has no backend).
    fetch("/api/model")
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        if (d && typeof d.model === "string") modelName = d.model;
        if (d && typeof d.version === "string") serverVersion = d.version;
        // Demo bot gate: load Turnstile's script once we know the sitekey (the
        // $effect below renders the widget into the intro modal). Explicit render so
        // we control placement + callbacks.
        if (d && typeof d.turnstile_sitekey === "string" && d.turnstile_sitekey) {
          turnstileSitekey = d.turnstile_sitekey;
          loadTurnstileScript();
          // Turnstile is REQUIRED: force the widget whenever we don't hold a token,
          // even if the info-intro was dismissed earlier (a reload clears the in-memory
          // token; an expired one is rejected server-side → re-prompt below).
          if (!demoToken) showIntro = true;
        }
      })
      .catch(() => {});
    // The model catalog + the current selection. Real install only — the demo/mock
    // can't restart the shared engine or download weights.
    if (!isDemo) {
      refreshModels();
      // Reflect any in-flight download (a user's, or the startup provisioner's) so
      // the catalog opens onto live progress rather than a stale "Download".
      fetch("/api/models/download/status")
        .then((r) => (r.ok ? r.json() : null))
        .then((d) => {
          if (d && d.state === "running") {
            dl = d;
            pollDownload();
          }
        })
        .catch(() => {});
    }
    // Bottom-bar backfill + GPU telemetry — only on a real install (the demo has no
    // System tab and shares a replay GPU). The mock (:5173) has no backend → fetch
    // fails quietly and the indicators just stay hidden.
    if (!isDemo) {
      pollTelemetry();
      setInterval(pollTelemetry, 2000);
    }
  });
  // shortId (engine id ↔ selectable id) lives in $lib/format (pure + unit-tested):
  // the live id (e.g. `Qwen/Qwen2.5-3B-Instruct-int4`) vs a selectable id differ by
  // org prefix + an `-int4` suffix, so both compare on the short, stripped form.
  // Switch the on-device model: POST the choice (the server rewrites the engine
  // config + restarts the engine), then poll until the engine is back serving it.
  async function selectModel(id: string) {
    if (!id || id === currentModel || switching) return;
    const prev = currentModel;
    switching = true;
    currentModel = id;
    try {
      const r = await fetch("/api/models/select", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ model: id }),
      });
      if (!r.ok) {
        currentModel = prev; // revert the dropdown if the server refused
        return;
      }
      const want = shortId(id);
      // The engine restarts (a brief down window), so poll its live `loaded` id.
      for (let i = 0; i < 40; i++) {
        await new Promise((res) => setTimeout(res, 1500));
        try {
          const m = await fetch("/api/models").then((x) => (x.ok ? x.json() : null));
          const loaded = m && typeof m.loaded === "string" ? m.loaded : "";
          if (loaded && loaded.toLowerCase().includes(want)) {
            modelName = m.loaded;
            break;
          }
        } catch {
          /* engine mid-restart — keep polling */
        }
      }
    } finally {
      switching = false;
    }
  }

  // ── model catalog (Use / Download) ─────────────────────────────────────────
  async function refreshModels() {
    try {
      const m = await fetch("/api/models").then((r) => (r.ok ? r.json() : null));
      if (m && Array.isArray(m.available)) models = m.available;
      if (m && typeof m.current === "string") currentModel = m.current;
      // -1/absent = server couldn't detect RAM → treat as unknown (0 disables the check).
      if (m && typeof m.memoryGb === "number" && m.memoryGb > 0) memoryGb = m.memoryGb;
    } catch {}
  }
  // Does model `m` plausibly fit in this Mac's RAM? Unknown memory (mock/older server)
  // or no advertised size → always "fits" (don't disable). We NEVER flag the currently
  // loaded/in-use model as won't-fit — it's demonstrably running (guarded at the call
  // site via isCurrent). `gb` is the bf16 download size, a conservative upper bound.
  function fits(m: { gb?: number }): boolean {
    if (!memoryGb || !m.gb) return true;
    return m.gb + RESERVE_GB <= memoryGb;
  }
  // Is `id` the model the engine is currently serving? The loaded id differs from a
  // catalog id by org prefix + an `-int4` suffix, so match on the short, stripped form.
  function isCurrent(id: string): boolean {
    return !!currentModel && shortId(id) === shortId(currentModel);
  }
  // Bytes → GiB with one decimal (for the download progress "X.X / Y.Y GB" readout).
  function fmtGB(bytes: number): string {
    return (bytes / (1 << 30)).toFixed(1);
  }
  // The catalog label for a model id (falls back to the last path segment).
  function labelFor(id: string): string {
    const m = models.find((x) => shortId(x.id) === shortId(id));
    return m ? m.label : id.slice(id.lastIndexOf("/") + 1);
  }
  // Start a background download of a not-yet-present model, then poll its progress
  // until it lands (or errors) — on completion the catalog row flips to "Use".
  async function downloadModel(id: string) {
    if (dl && dl.state === "running") return; // one at a time (server also guards)
    try {
      const r = await fetch("/api/models/download", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ model: id }),
      });
      if (!r.ok) {
        const e = await r.json().catch(() => ({}));
        dl = { model: id, state: "error", detail: e.error ?? "download failed" };
        return;
      }
      dl = { model: id, state: "running", detail: "starting…" };
      pollDownload();
    } catch {
      dl = { model: id, state: "error", detail: "download failed" };
    }
  }
  function pollDownload() {
    clearTimeout(dlTimer);
    dlTimer = setTimeout(async () => {
      try {
        const d = await fetch("/api/models/download/status").then((r) => (r.ok ? r.json() : null));
        if (d) {
          dl = d;
          if (d.state === "done") {
            await refreshModels(); // the row flips to Use (downloaded:true)
            setTimeout(() => { if (dl && dl.state === "done") dl = null; }, 2500);
            return;
          }
          if (d.state === "error") return; // leave the error visible
        }
      } catch {}
      pollDownload();
    }, 1500);
  }

  function dismissIntro() {
    showIntro = false;
    try {
      sessionStorage.setItem(INTRO_KEY, "1");
    } catch {}
  }

  // ── Turnstile (demo only) ──────────────────────────────────────────────────
  const TURNSTILE_SRC =
    "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
  let turnstileScriptLoaded = $state(false);
  function loadTurnstileScript() {
    if (typeof document === "undefined") return;
    if ((window as any).turnstile) { turnstileScriptLoaded = true; return; }
    if (document.querySelector(`script[src="${TURNSTILE_SRC}"]`)) return;
    const s = document.createElement("script");
    s.src = TURNSTILE_SRC;
    s.async = true;
    s.defer = true;
    s.onload = () => (turnstileScriptLoaded = true);
    document.head.appendChild(s);
  }
  // Render the widget once the modal is up, the script is ready, and we haven't yet.
  $effect(() => {
    if (!showIntro || !turnstileSitekey || !turnstileScriptLoaded) return;
    if (!turnstileEl || turnstileWidgetId !== undefined) return;
    const ts = (window as any).turnstile;
    if (!ts) return;
    turnstileWidgetId = ts.render(turnstileEl, {
      sitekey: turnstileSitekey,
      callback: (t: string) => { turnstileToken = t; turnstileError = ""; },
      "expired-callback": () => (turnstileToken = ""),
      "error-callback": () => { turnstileToken = ""; turnstileError = "Verification failed — please retry."; },
    });
  });
  // "Got it": when the gate is on, verify the Turnstile token server-side (mints the
  // demo-access token) BEFORE dismissing; otherwise just dismiss.
  async function acknowledgeIntro() {
    if (!turnstileSitekey) { dismissIntro(); return; }
    if (!turnstileToken || verifying) return;
    verifying = true;
    turnstileError = "";
    try {
      const r = await fetch("/api/demo/verify", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: turnstileToken }),
      });
      if (!r.ok) throw new Error();
      const d = await r.json();
      demoToken = d.token ?? "";
      try { sessionStorage.setItem(DEMO_TOKEN_KEY, demoToken); } catch {}
      dismissIntro();
    } catch {
      turnstileError = "Verification failed — please retry.";
      turnstileToken = "";
      const ts = (window as any).turnstile;
      if (ts && turnstileWidgetId !== undefined) ts.reset(turnstileWidgetId);
    } finally {
      verifying = false;
    }
  }

  // Safe unique id: crypto.randomUUID() throws in a non-secure context (plain
  // http:// over a raw Tailscale IP) and is missing on older mobile Safari — which
  // would abort send() *before* the user's question is added. Fall back so a
  // question (and every event) always renders.
  function uid(): string {
    try {
      if (typeof crypto !== "undefined" && crypto.randomUUID) return crypto.randomUUID();
    } catch {}
    return `id-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
  }

  function handle(e: ServerEvent) {
    switch (e.type) {
      case "status": {
        // The run-queue position renders as a floating corner badge, not inline.
        if (e.stepId === "queue") {
          queueMsg = e.state === "running" ? e.label : null;
          break;
        }
        // Update the status line in place (keyed by stepId) — but ONLY within the
        // current turn (after the last user message), so a new question's statuses
        // don't update the PREVIOUS question's lines (which left them looking stuck).
        let lastUser = -1;
        for (let k = 0; k < items.length; k++) if (items[k].kind === "user") lastUser = k;
        const i = items.findIndex(
          (x, idx) => idx > lastUser && x.kind === "status" && x.stepId === e.stepId,
        );
        if (i === -1) {
          items.push({ kind: "status", id: uid(), stepId: e.stepId, label: e.label, state: e.state, detail: e.detail });
        } else {
          const cur = items[i];
          // Narrow before spreading — re-indexing items[] loses the union narrowing,
          // and a bare spread would widen the result off the ChatItem union (svelte-check).
          if (cur.kind === "status")
            items[i] = { ...cur, label: e.label, state: e.state, detail: e.detail };
        }
        if (e.state === "awaiting-approval") busy = false; // hand control to the user
        break;
      }
      case "approval-request":
        items.push({ kind: "approval", id: uid(), stepId: e.stepId, title: e.payload.title, body: e.payload.body, language: e.payload.language });
        break;
      case "tags":
        // Which category tags the generated program filtered on — a chip so the
        // user knows the answer came from a tag, not a guess.
        if (e.tags) items.push({ kind: "tags", id: uid(), tags: e.tags });
        break;
      case "tag-proposal":
        // The model suggested a reusable tag for a category that isn't one yet —
        // surface it so the user can save it (next time = a fast .tags filter).
        // AI form carries `prompt` (a yes/no question); keyword form carries `keywords`.
        if (e.name && (e.prompt || e.keywords))
          items.push({
            kind: "tag-proposal",
            id: uid(),
            name: e.name,
            ml: !!e.ml,
            keywords: e.keywords ?? "",
            prompt: e.prompt ?? "",
          });
        break;
      case "debug":
        items.push({ kind: "debug", id: uid(), title: e.title, body: e.body, language: e.language });
        break;
      case "message":
        // NB: the server stamps every message with id "msg" (events.mojo), so two
        // identical answers (same cached program → same reply) would collide on the
        // {#each items (it.id)} key and Svelte would silently drop the 2nd — the
        // classic "2nd question hangs". Key on a fresh unique id, not the server's.
        items.push({ kind: "assistant", id: uid(), text: e.text, source: e.source, sourceAlias: e.sourceAlias, result: e.result });
        busy = false;
        queueMsg = null;
        break;
      case "error":
        // The demo bot gate rejected this ask (no/expired token) → drop the stale
        // token and re-show the Turnstile widget so the user can re-verify.
        if (turnstileSitekey && e.message && e.message.toLowerCase().includes("human check")) {
          demoToken = "";
          turnstileToken = "";
          try { sessionStorage.removeItem(DEMO_TOKEN_KEY); } catch {}
          const ts = (window as any).turnstile;
          if (ts && turnstileWidgetId !== undefined) { try { ts.reset(turnstileWidgetId); } catch {} }
          turnstileWidgetId = undefined; // re-render into the modal on reopen
          showIntro = true;
        }
        items.push({ kind: "assistant", id: uid(), text: `Error: ${e.message}` });
        busy = false;
        queueMsg = null;
        break;
    }
  }

  function send(text: string) {
    items.push({ kind: "user", id: uid(), text });
    busy = true;
    session = client.ask(text, handle);
  }

  // "Run again" — re-run a SAVED program directly (no model call). Mark it in the
  // timeline with a user-style "Run again: <q>" bubble, then stream the answer with the
  // SAME event handler as a normal ask (status/message/result render identically).
  function runAgain(program: string, q: string) {
    items.push({ kind: "user", id: uid(), text: `Run again: ${q}` });
    busy = true;
    session = client.run(program, q, handle);
  }

  function resolve(id: string, decision: "approved" | "rejected") {
    const i = items.findIndex((x) => x.id === id);
    if (i !== -1 && items[i].kind === "approval") items[i] = { ...items[i], resolved: decision };
  }
  function approve(id: string, stepId: string) {
    resolve(id, "approved");
    busy = true;
    session?.approve(stepId);
  }
  function reject(id: string, stepId: string) {
    resolve(id, "rejected");
    session?.reject(stepId, "rejected by user");
  }
</script>

<!-- Escape closes the intro only when the human-check gate isn't active (don't let it be bypassed). -->
<svelte:window onkeydown={(e) => {
  if (showIntro && !turnstileSitekey && e.key === "Escape") dismissIntro();
  else if (catalogOpen && e.key === "Escape") catalogOpen = false;
}} />

{#if catalogOpen}
  <!-- Click-away backdrop for the model catalog popover. -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="catalog-backdrop" onclick={() => (catalogOpen = false)}></div>
{/if}

<!-- First-run liability/privacy notice — real install only (the public demo shows
     its own "About this demo" intro instead). Self-gates on a localStorage flag. -->
{#if !isDemo}
  <DisclaimerNotice />
{/if}

{#if showIntro}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="intro-backdrop" role="presentation" onclick={(e) => { if (e.target === e.currentTarget && !turnstileSitekey) dismissIntro(); }}>
    <div class="intro-card" role="dialog" aria-modal="true" aria-labelledby="intro-title" tabindex="-1">
      <h2 id="intro-title">About this demo</h2>
      <p>
        This application must be installed and run on your own Mac (mini) computer. It
        relies on a local model to see your data and on a foundational model to write
        code. In this demo the local model really runs on a Mac mini; only the
        foundational model is stubbed out (its answers are replayed).
      </p>
      <p>
        Because everything runs on that one Mac mini, requests are handled one at a
        time — if others are ahead of you, you'll wait your turn.
      </p>
      <p>
        See <a href="https://millfolio.app" target="_blank" rel="noopener">millfolio.app</a>.
      </p>
      {#if turnstileSitekey}
        <p class="ts-prompt">Quick human check to start the demo:</p>
        <div class="ts-widget" bind:this={turnstileEl}></div>
        {#if turnstileError}<p class="ts-error" role="alert">{turnstileError}</p>{/if}
      {/if}
      <button
        class="intro-ok"
        onclick={acknowledgeIntro}
        disabled={verifying || (!!turnstileSitekey && !turnstileToken)}
      >
        {verifying ? "Verifying…" : "Got it"}
      </button>
    </div>
  </div>
{/if}

{#if queueMsg}
  <div class="queue-badge" role="status" aria-live="polite">⏳ {queueMsg}</div>
{/if}

<main>
  <header class="topbar">
    <nav class="tabs">
      <a class:active={view === "chat"} href="/">Chat</a>
      <!-- Millwright: the pinned-answers board. Demo edits live in the browser. -->
      <a class:active={view === "board" && !page.params.tab?.startsWith("p-")} href="/board">Board</a>
      <!-- Spec-defined pages: ADDITIVE nav only — the built-ins above are
           hand-written routes no spec can move, rename, or remove. -->
      {#each mwPages as p (p.id)}
        <a class:active={page.params.tab === p.id} href="/{p.id}">{p.title}</a>
      {/each}
      <a class:active={view === "vault" || view === "tags"} href="/vault">Vault</a>
      {#if isDemo}
        <!-- The public demo has no Operations tab, so Stats stays top-level. -->
        <a class:active={view === "stats"} href="/stats">Stats</a>
      {:else}
        <!-- Real install: one Operations tab = the machine-activity page, with
             Operations | Stats | Logs sub-tabs (Now/Controls/History/System/Backfill,
             per-question timing, and the on-disk data & log locations). -->
        <a class:active={view === "operations"} href="/operations">Operations</a>
      {/if}
    </nav>
    <!-- The website's top-right set: docs, the org, the discussion board, and chat. -->
    <nav class="links">
      <a href="https://millfolio.app/docs" target="_blank" rel="noopener">Docs</a>
      <a href="https://github.com/millfolio" target="_blank" rel="noopener">github.com/millfolio ↗</a>
      <a href="https://github.com/millfolio/millfolio/discussions" target="_blank" rel="noopener" title="Join the discussion">Community ↗</a>
      <a href="https://discord.gg/ZrWcStMtE4" target="_blank" rel="noopener" title="Join the Discord">Discord ↗</a>
    </nav>
  </header>
  {#if showOnboarding}
    <section class="onboarding" aria-labelledby="onb-title">
      <h2 id="onb-title">Welcome to {brandName}</h2>
      <p class="onb-lead">
        Your vault is empty. Add a folder of your own statements under
        <a href="/vault">Vault → Files</a> (see the
        <a href="https://millfolio.app/docs/files" target="_blank" rel="noopener">indexing guide</a>),
        or try it right now with sample data.
      </p>
      <div class="onb-actions">
        {#if !demoImport}
          <button class="onb-primary" onclick={startDemoImport}>Download demo data</button>
          <span class="onb-hint">A few sample bank &amp; card statements (~444 transactions).</span>
        {:else if demoImport.state === "downloading" || demoImport.state === "indexing"}
          {@const pct = typeof demoImport.progress === "number" && demoImport.progress >= 0 ? demoImport.progress : -1}
          {@const idxN = demoImport.state === "indexing" && typeof demoImport.current === "number" && typeof demoImport.total === "number" && demoImport.total > 0 ? `${demoImport.current} of ${demoImport.total} files` : ""}
          <div class="onb-progress-wrap" role="status" aria-live="polite">
            <span class="onb-progress">
              {#if pct < 0}<span class="onb-spinner" aria-hidden="true"></span>{/if}
              {#if demoImport.state === "downloading"}
                {pct >= 0 ? `Downloading sample data — ${pct}%` : "Downloading sample data…"}
              {:else}
                Indexing sample data{idxN ? ` — ${idxN}` : " (first run loads the embedding model)…"}
              {/if}
            </span>
            {#if pct >= 0}
              <div
                class="onb-bar"
                role="progressbar"
                aria-valuemin="0"
                aria-valuemax="100"
                aria-valuenow={pct}
              >
                <div class="onb-bar-fill" style={`width:${pct}%`}></div>
              </div>
            {/if}
          </div>
        {:else if demoImport.state === "error"}
          <span class="onb-error" role="alert">Couldn’t load sample data: {demoImport.detail}</span>
          <button class="onb-primary" onclick={startDemoImport}>Retry</button>
        {:else if demoImport.state === "done"}
          <span class="onb-ready">✓ Sample data ready — ask away.</span>
        {/if}
      </div>
      <div class="onb-suggest">
        <span class="onb-suggest-label">Try asking:</span>
        <div class="onb-chips">
          {#each DEMO_QUESTIONS as q}
            <button
              class="onb-chip"
              disabled={!demoReady}
              title={demoReady ? "Ask this question" : "Load some data first"}
              onclick={() => askSuggested(q)}
            >{q}</button>
          {/each}
        </div>
      </div>
      <a class="onb-more" href="https://millfolio.app/get-started#index" target="_blank" rel="noopener">Getting started →</a>
    </section>
  {/if}
  <div class="single">
    {#if view === "chat"}
      <ChatPanel {items} {busy} demo={isDemo} onsend={send} onrun={runAgain} onapprove={approve} onreject={reject} />
    {:else if view === "board"}
      <!-- Millwright: the versioned dashboard of pinned answers (trusted chrome). -->
      {#key page.params.tab}
        <MillwrightPanel {client} demo={isDemo} pageId={page.params.tab?.startsWith("p-") ? page.params.tab : ""} />
      {/key}
    {:else if view === "vault"}
      <VaultPanel demo={isDemo} initialSub="records" />
    {:else if view === "tags"}
      <!-- /tags deep-links (tag pills) open the Vault → Tags sub-tab. -->
      <VaultPanel demo={isDemo} initialSub="tags" />
    {:else if view === "operations"}
      <!-- The machine-activity page with Operations | Stats | Logs sub-tabs. Re-key on
           the URL-selected sub-tab so a /stats deep-link remounts onto the Stats sub-tab
           (the wrapper captures its initial sub-tab once, like VaultPanel). -->
      {#key opSub}
        <OperationsView demo={isDemo} initialSub={opSub} />
      {/key}
    {:else if view === "stats"}
      <!-- Demo only — the standalone Stats page (the demo has no Operations tab). -->
      <StatsPanel />
    {:else}
      <ChatPanel {items} {busy} demo={isDemo} onsend={send} onrun={runAgain} onapprove={approve} onreject={reject} />
    {/if}
  </div>
  <footer class="statusbar">
    {#if !isDemo && models.length > 0}
      <span class="model catalog">
        <span class="dot" aria-hidden="true"></span>
        <button
          class="modelbtn"
          onclick={() => (catalogOpen = !catalogOpen)}
          disabled={switching}
          aria-haspopup="menu"
          aria-expanded={catalogOpen}
          title="on-device model — Use a downloaded model or download another"
        >
          {labelFor(currentModel)}{#if switching}<span class="switching"> · switching…</span>{/if} ▾
        </button>
        {#if catalogOpen}
          <div class="catalog-pop" role="menu">
            <div class="catalog-head">On-device models</div>
            {#each models as m (m.id)}
              <div class="catalog-row" role="menuitem">
                <span class="cm-label">
                  {m.label}
                  {#if m.gb}<span class="cm-gb">~{m.gb} GB</span>{/if}
                </span>
                {#if isCurrent(m.id)}
                  <!-- Never won't-fit: the loaded model is demonstrably running. -->
                  <span class="cm-badge">In use</span>
                {:else if !fits(m)}
                  <button
                    class="cm-nofit"
                    disabled
                    title={`Needs ~${m.gb} GB; this Mac has ${memoryGb} GB`}
                  >Won't fit in memory</button>
                {:else if m.downloaded}
                  <button
                    class="cm-use"
                    disabled={switching}
                    onclick={() => { selectModel(m.id); catalogOpen = false; }}
                  >Use</button>
                {:else if dl && dl.model === m.id && dl.state === "running"}
                  {#if typeof dl.progress === "number" && dl.progress >= 0}
                    <span class="cm-progbar" title={dl.detail} role="progressbar" aria-valuenow={dl.progress} aria-valuemin="0" aria-valuemax="100">
                      <span class="cm-bar"><span class="cm-fill" style="width:{dl.progress}%"></span></span>
                      <span class="cm-pct">{dl.progress}%</span>
                    </span>
                  {:else}
                    <span class="cm-prog" title={dl.detail}>Downloading…</span>
                  {/if}
                {:else if dl && dl.model === m.id && dl.state === "error"}
                  <button class="cm-dl" onclick={() => downloadModel(m.id)}>Retry</button>
                {:else}
                  <button
                    class="cm-dl"
                    disabled={!!(dl && dl.state === "running")}
                    onclick={() => downloadModel(m.id)}
                  >Download</button>
                {/if}
              </div>
            {/each}
            {#if dl && dl.state === "running"}
              <div class="catalog-foot" title={dl.detail}>
                Downloading {labelFor(dl.model)}…
                {#if typeof dl.progress === "number" && dl.progress >= 0}
                  {dl.progress}%{#if dl.bytesTotal && dl.bytesTotal > 0 && dl.bytesDone !== undefined && dl.bytesDone >= 0}
                    <span class="cf-detail"> · {fmtGB(dl.bytesDone)} / {fmtGB(dl.bytesTotal)} GB</span>
                  {/if}
                {:else}
                  <span class="cf-detail">{dl.detail}</span>
                {/if}
              </div>
            {:else if dl && dl.state === "error"}
              <div class="catalog-foot err">Download failed: {dl.detail}</div>
            {/if}
          </div>
        {/if}
      </span>
    {:else if modelName}
      <span class="model" title="on-device model answering your questions">
        <span class="dot" aria-hidden="true"></span>{modelName}
      </span>
    {/if}
    {#if !isDemo && idxRunning}
      <a
        class="metric link"
        href="/operations"
        title="Indexing in progress — click to open Operations"
      >
        <span class="mlabel">Index</span>
        {#if idxTotal && idxTotal > 0 && idxCurrent !== null}{idxCurrent}/{idxTotal}{:else}running{/if}
      </a>
    {/if}
    {#if !isDemo && bkPending > 0}
      <a
        class="metric link"
        href="/operations"
        title="AI-tag backfill in progress — click to open Operations → Backfill"
      >
        <span class="mlabel">Backfill</span>
        {#if bkEta && bkEta > 0}~{fmtEta(bkEta)}{:else}{bkPending} left{/if}
        {#if bkPriority}· {bkPriority}{/if}
      </a>
    {/if}
    {#if !isDemo && gpuAvg !== null}
      <span class="metric" title="average GPU utilization over the last 30 seconds">
        GPU avg: {gpuAvg}%
      </span>
    {/if}
    {#if !isDemo && memUsed !== null}
      <span class="metric" title="system memory in use (app + wired + compressed)">
        MEM: {memUsed}%
      </span>
    {/if}
    {#if !isDemo && diskUsed !== null}
      <span class="metric" title="disk in use on the volume holding the vault + model weights">
        DISK: {diskUsed}%
      </span>
    {/if}
    <span class="spacer"></span>
    <span class="ver" title="build (app SHA · release version)">{buildLabel}</span>
  </footer>
</main>

<style>
  main {
    height: 100vh; /* fallback for browsers without dvh */
    height: 100dvh; /* dynamic viewport — excludes the iOS Safari URL bar */
    display: flex;
    flex-direction: column;
  }
  .topbar {
    display: flex;
    align-items: center;
    flex-wrap: wrap; /* mobile: links wrap under the tabs, never overflow */
    gap: 10px 18px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
  }
  .tabs {
    display: flex;
    gap: 4px;
  }
  .tabs a {
    padding: 5px 12px;
    border-radius: var(--radius);
    border: 1px solid transparent;
    background: transparent;
    color: var(--text-dim);
    font-weight: 600;
    font-size: 13px;
    text-decoration: none;
    cursor: pointer;
  }
  .tabs a:hover {
    color: var(--text);
  }
  .tabs a.active {
    background: var(--surface-2);
    border-color: var(--border);
    color: var(--text);
  }
  .links {
    margin-left: auto; /* push the trio to the top-right */
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 14px;
  }
  .links a {
    color: var(--text-dim);
    font-weight: 600;
    font-size: 13px;
    text-decoration: none;
    white-space: nowrap;
  }
  .links a:hover {
    color: var(--accent);
  }
  .single {
    flex: 1;
    min-height: 0;
    display: grid;
  }
  /* ── first-run onboarding (empty-vault welcome + sample-data offer) ───────── */
  .onboarding {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 20px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--surface-2);
    color: var(--text-dim);
    font-size: 14px;
    line-height: 1.5;
  }
  .onboarding h2 {
    margin: 0;
    color: var(--text);
    font-size: 18px;
    font-weight: 700;
  }
  .onb-lead {
    margin: 0;
    max-width: 60ch;
  }
  .onboarding code {
    padding: 1px 5px;
    border-radius: 4px;
    background: var(--surface);
    border: 1px solid var(--border);
    font-size: 12px;
    white-space: nowrap; /* keep `mill index <dir>` on one line — it was breaking
                            mid-command (mill / index <dir>) and reading as broken */
  }
  .onb-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 10px 14px;
  }
  .onb-primary {
    padding: 8px 16px;
    border: 1px solid var(--accent);
    border-radius: 6px;
    background: var(--accent);
    color: #fff;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
  }
  .onb-primary:hover {
    filter: brightness(1.06);
  }
  .onb-hint {
    font-size: 12px;
    color: var(--text-dim);
  }
  .onb-progress-wrap {
    display: flex;
    flex-direction: column;
    gap: 8px;
    min-width: 220px;
  }
  .onb-progress {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    color: var(--text);
    font-variant-numeric: tabular-nums;
  }
  .onb-bar {
    height: 6px;
    border-radius: 999px;
    background: var(--surface-2, var(--border));
    overflow: hidden;
  }
  .onb-bar-fill {
    height: 100%;
    background: var(--accent);
    border-radius: 999px;
    transition: width 0.3s ease;
  }
  .onb-spinner {
    width: 14px;
    height: 14px;
    border: 2px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: onb-spin 0.8s linear infinite;
  }
  @keyframes onb-spin {
    to {
      transform: rotate(360deg);
    }
  }
  .onb-error {
    color: var(--danger, #d24545);
  }
  .onb-ready {
    color: var(--text);
    font-weight: 600;
  }
  .onb-suggest {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .onb-suggest-label {
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text-dim);
  }
  .onb-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }
  .onb-chip {
    padding: 6px 12px;
    border: 1px solid var(--border);
    border-radius: 999px;
    background: var(--surface);
    color: var(--text);
    font-size: 13px;
    cursor: pointer;
    text-align: left;
  }
  .onb-chip:hover:not(:disabled) {
    border-color: var(--accent);
    color: var(--accent);
  }
  .onb-chip:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .onb-more {
    align-self: flex-start;
    color: var(--accent);
    font-weight: 600;
    text-decoration: none;
    font-size: 13px;
  }
  .onb-more:hover {
    text-decoration: underline;
  }
  .intro-backdrop {
    position: fixed;
    inset: 0;
    z-index: 50;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 20px;
    background: rgba(0, 0, 0, 0.55);
  }
  .intro-card {
    max-width: 460px;
    width: 100%;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 22px 24px;
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.4);
    text-align: center;
  }
  .intro-card h2 {
    margin: 0 0 12px;
    font-size: 16px;
    font-weight: 700;
  }
  .intro-card p {
    margin: 0 0 12px;
    color: var(--text-dim);
    line-height: 1.5;
    font-size: 14px;
  }
  .intro-card a {
    color: var(--accent);
  }
  .intro-ok {
    margin-top: 6px;
    padding: 7px 16px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--accent);
    color: #00132e;
    font-weight: 600;
    font-size: 13px;
    cursor: pointer;
  }
  .intro-ok:hover {
    filter: brightness(1.08);
  }
  .intro-ok:disabled {
    opacity: 0.5;
    cursor: default;
    filter: none;
  }
  .ts-prompt {
    margin: 4px 0 8px !important;
    font-weight: 600;
    color: var(--text) !important;
  }
  .ts-widget {
    min-height: 65px;
    margin-bottom: 6px;
  }
  .ts-error {
    color: var(--warn, #e5484d) !important;
    font-size: 12px;
    margin: 0 0 8px !important;
  }
  .queue-badge {
    position: fixed;
    right: 16px;
    bottom: 40px; /* clear the bottom status bar */
    z-index: 40;
    padding: 8px 14px;
    border-radius: var(--radius);
    border: 1px solid var(--accent);
    background: var(--surface);
    color: var(--text);
    font-size: 13px;
    font-weight: 600;
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35);
  }
  @media (max-width: 480px) {
    .queue-badge { right: 8px; bottom: 34px; font-size: 12px; }
  }
  .statusbar {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 4px 14px;
    border-top: 1px solid var(--border);
    background: var(--surface);
    font-size: 12px;
    color: var(--text-dim);
    min-height: 26px;
  }
  .statusbar .spacer {
    flex: 1;
  }
  .statusbar .model {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: var(--text);
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }
  .statusbar .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent);
  }
  /* Inline model catalog trigger — looks like the label text, not a boxed control. */
  .statusbar .model.catalog {
    position: relative;
  }
  .statusbar .modelbtn {
    appearance: none;
    background: transparent;
    border: none;
    color: inherit;
    font: inherit;
    font-weight: 600;
    cursor: pointer;
    padding: 0 2px;
    max-width: 26ch;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .statusbar .modelbtn:hover {
    color: var(--accent);
  }
  .statusbar .modelbtn:disabled {
    cursor: progress;
    opacity: 0.7;
  }
  .statusbar .switching {
    color: var(--muted, #888);
    font-weight: 400;
  }
  .catalog-backdrop {
    position: fixed;
    inset: 0;
    z-index: 45;
  }
  /* The popover opens UPWARD from the footer chip. */
  .statusbar .catalog-pop {
    position: absolute;
    bottom: calc(100% + 8px);
    left: 0;
    z-index: 46;
    min-width: 260px;
    max-width: 340px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.4);
    padding: 6px;
    font-weight: 400;
  }
  .catalog-head {
    padding: 4px 8px 6px;
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-dim);
  }
  .catalog-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 6px 8px;
    border-radius: 6px;
  }
  .catalog-row:hover {
    background: var(--surface-2);
  }
  .cm-label {
    display: inline-flex;
    align-items: baseline;
    gap: 6px;
    color: var(--text);
    font-weight: 600;
  }
  .cm-gb {
    color: var(--text-dim);
    font-weight: 400;
    font-size: 11px;
  }
  .cm-badge {
    color: var(--accent);
    font-size: 11px;
    font-weight: 600;
  }
  .cm-prog {
    color: var(--text-dim);
    font-size: 11px;
  }
  /* Determinate download progress: a thin track + fill and a NN% readout. */
  .cm-progbar {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .cm-bar {
    width: 72px;
    height: 4px;
    border-radius: 3px;
    background: var(--surface-2);
    overflow: hidden;
  }
  .cm-fill {
    display: block;
    height: 100%;
    background: var(--accent);
    border-radius: 3px;
    transition: width 0.3s ease;
  }
  .cm-pct {
    color: var(--text-dim);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }
  /* Won't-fit: a disabled, dimmed pseudo-button matching the catalog buttons. */
  .cm-nofit {
    appearance: none;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--surface-2);
    color: var(--text-dim);
    font-size: 11px;
    font-weight: 600;
    padding: 3px 10px;
    opacity: 0.55;
    cursor: not-allowed;
  }
  .cm-use,
  .cm-dl {
    appearance: none;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--surface-2);
    color: var(--text);
    font-size: 11px;
    font-weight: 600;
    padding: 3px 10px;
    cursor: pointer;
  }
  .cm-dl {
    border-color: var(--accent);
    color: var(--accent);
  }
  .cm-use:hover,
  .cm-dl:hover:not(:disabled) {
    filter: brightness(1.1);
    background: var(--surface);
  }
  .cm-use:disabled,
  .cm-dl:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .catalog-foot {
    padding: 6px 8px 2px;
    margin-top: 4px;
    border-top: 1px solid var(--border);
    color: var(--text-dim);
    font-size: 11px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .catalog-foot.err {
    color: var(--warn, #e5484d);
  }
  .cf-detail {
    opacity: 0.75;
  }
  .statusbar .metric {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
    text-decoration: none;
  }
  .statusbar .metric.link {
    cursor: pointer;
  }
  .statusbar .metric.link:hover {
    color: var(--accent);
  }
  .statusbar .mlabel {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  .statusbar .ver {
    opacity: 0.6;
    font-variant-numeric: tabular-nums;
    user-select: none;
  }
</style>
