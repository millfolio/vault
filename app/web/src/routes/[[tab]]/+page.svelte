<script lang="ts">
  import { onMount } from "svelte";
  import { page } from "$app/state";
  import ChatPanel from "$lib/components/ChatPanel.svelte";
  import VaultPanel from "$lib/components/VaultPanel.svelte";
  import StatsPanel from "$lib/components/StatsPanel.svelte";
  import SystemPanel from "$lib/components/SystemPanel.svelte";
  import { createMockClient } from "$lib/client";
  import { createWsClient } from "$lib/wsClient";
  import type { ServerEvent, Session, MillfolioClient, StepState } from "$lib/protocol";

  // One inline timeline: chat bubbles + the workflow events (status/debug/approval)
  // rendered in place, instead of a separate workflow pane.
  type ChatItem =
    | { kind: "user" | "assistant"; id: string; text: string; source?: string; sourceAlias?: string }
    | { kind: "status"; id: string; stepId: string; label: string; state: StepState; detail?: string }
    | { kind: "debug"; id: string; title: string; body: string; language?: string }
    | { kind: "tags"; id: string; tags: string }
    | { kind: "tag-proposal"; id: string; name: string; keywords: string }
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
    return createWsClient(`${scheme}://${location.host}/chat`);
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
  // "/vault" → vault, "/stats" → stats, "/system" → system. One component serves all
  // tabs, so switching is a same-route param change (no remount) — the chat survives.
  const view = $derived<"chat" | "vault" | "stats" | "system" | "tags">(
    page.params.tab === "vault"
      ? "vault"
      : page.params.tab === "stats"
        ? "stats"
        : page.params.tab === "system"
          ? "system"
          : page.params.tab === "tags"
            ? "tags"
            : "chat",
  );
  // Run-queue position — shown as a floating bottom-right badge, not inline.
  let queueMsg = $state<string | null>(null);
  // The on-device model the server serves (bottom status bar). Empty under the
  // in-browser mock (:5173, no backend) — the bar just omits it then.
  let modelName = $state("");
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

  // Intro disclaimer — ONLY the public demo shows it (it explains the replay/queue
  // caveats that don't apply to a real local install). Remembered per browser session
  // so a reload within the same tab doesn't nag, but every new visitor sees it once.
  const INTRO_KEY = "millfolio-demo-intro-dismissed";
  let showIntro = $state(false);
  // Outside the demo: true when the on-device vault has nothing indexed yet, so we can
  // prompt the user to run `mill index` instead of dropping them into an empty chat.
  let vaultEmpty = $state(false);
  onMount(() => {
    if (isDemo) {
      try {
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
    }
    // Ask the server which model it's serving (best-effort; mock has no backend).
    fetch("/api/model")
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        if (d && typeof d.model === "string") modelName = d.model;
        if (d && typeof d.version === "string") serverVersion = d.version;
      })
      .catch(() => {});
  });
  function dismissIntro() {
    showIntro = false;
    try {
      sessionStorage.setItem(INTRO_KEY, "1");
    } catch {}
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
        if (e.name && e.keywords)
          items.push({ kind: "tag-proposal", id: uid(), name: e.name, keywords: e.keywords });
        break;
      case "debug":
        items.push({ kind: "debug", id: uid(), title: e.title, body: e.body, language: e.language });
        break;
      case "message":
        // NB: the server stamps every message with id "msg" (events.mojo), so two
        // identical answers (same cached program → same reply) would collide on the
        // {#each items (it.id)} key and Svelte would silently drop the 2nd — the
        // classic "2nd question hangs". Key on a fresh unique id, not the server's.
        items.push({ kind: "assistant", id: uid(), text: e.text, source: e.source, sourceAlias: e.sourceAlias });
        busy = false;
        queueMsg = null;
        break;
      case "error":
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

<svelte:window onkeydown={(e) => { if (showIntro && e.key === "Escape") dismissIntro(); }} />

{#if showIntro}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="intro-backdrop" role="presentation" onclick={(e) => { if (e.target === e.currentTarget) dismissIntro(); }}>
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
      <button class="intro-ok" onclick={dismissIntro}>Got it</button>
    </div>
  </div>
{/if}

{#if queueMsg}
  <div class="queue-badge" role="status" aria-live="polite">⏳ {queueMsg}</div>
{/if}

<main>
  <header class="topbar">
    <a class="brand" href={`https://${brandName}.app`} title={`Go to ${brandName}.app`}>{brandName}</a>
    <nav class="tabs">
      <a class:active={view === "chat"} href="/">Chat</a>
      <a class:active={view === "vault" || view === "tags"} href="/vault">Vault</a>
      {#if isDemo}
        <!-- The public demo has no System tab, so Stats stays top-level. -->
        <a class:active={view === "stats"} href="/stats">Stats</a>
      {:else}
        <!-- Real install: Stats + Logs + Materialization live under one System tab. -->
        <a class:active={view === "system" || view === "stats"} href="/system">System</a>
      {/if}
    </nav>
    <a class="community" href="https://github.com/millfolio/millfolio/discussions" target="_blank" rel="noopener" title="Join the discussion">Community ↗</a>
  </header>
  {#if vaultEmpty && view === "chat"}
    <div class="notice" role="status">
      <strong>No documents in your vault yet.</strong>
      <span>
        Index a folder with <code>mill index &lt;dir&gt;</code>, then come back and ask away.
      </span>
      <a href="https://millfolio.app/get-started#index" target="_blank" rel="noopener">Getting started →</a>
    </div>
  {/if}
  <div class="single">
    {#if view === "chat"}
      <ChatPanel {items} {busy} demo={isDemo} onsend={send} onapprove={approve} onreject={reject} />
    {:else if view === "vault"}
      <VaultPanel demo={isDemo} initialSub="records" />
    {:else if view === "tags"}
      <!-- /tags deep-links (tag pills) open the Vault → Tags sub-tab. -->
      <VaultPanel demo={isDemo} initialSub="tags" />
    {:else if view === "system"}
      <SystemPanel demo={isDemo} initialSub="materialization" />
    {:else if view === "stats"}
      <!-- Demo keeps a dedicated Stats tab; the real app opens System on its Stats sub-tab. -->
      {#if isDemo}
        <StatsPanel />
      {:else}
        <SystemPanel demo={isDemo} initialSub="stats" />
      {/if}
    {:else}
      <ChatPanel {items} {busy} demo={isDemo} onsend={send} onapprove={approve} onreject={reject} />
    {/if}
  </div>
  <footer class="statusbar">
    {#if modelName}
      <span class="model" title="on-device model answering your questions">
        <span class="dot" aria-hidden="true"></span>{modelName}
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
    gap: 18px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
  }
  .brand {
    font-weight: 700;
    letter-spacing: 0.02em;
    color: inherit;
    text-decoration: none;
  }
  .brand:hover {
    color: var(--accent);
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
  .community {
    margin-left: auto; /* push to the top-right */
    color: var(--text-dim);
    font-weight: 600;
    font-size: 13px;
    text-decoration: none;
    white-space: nowrap;
  }
  .community:hover {
    color: var(--accent);
  }
  .single {
    flex: 1;
    min-height: 0;
    display: grid;
  }
  .notice {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 6px 10px;
    padding: 10px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--surface-2);
    color: var(--text-dim);
    font-size: 13px;
    line-height: 1.5;
  }
  .notice strong {
    color: var(--text);
  }
  .notice code {
    padding: 1px 5px;
    border-radius: 4px;
    background: var(--surface);
    border: 1px solid var(--border);
    font-size: 12px;
  }
  .notice a {
    margin-left: auto;
    color: var(--accent);
    font-weight: 600;
    text-decoration: none;
    white-space: nowrap;
  }
  .notice a:hover {
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
  .statusbar .ver {
    opacity: 0.6;
    font-variant-numeric: tabular-nums;
    user-select: none;
  }
</style>
