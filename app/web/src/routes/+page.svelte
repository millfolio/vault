<script lang="ts">
  import { onMount } from "svelte";
  import ChatPanel from "$lib/components/ChatPanel.svelte";
  import VaultPanel from "$lib/components/VaultPanel.svelte";
  import { createMockClient } from "$lib/client";
  import { createWsClient } from "$lib/wsClient";
  import type { ServerEvent, Session, MillfolioClient, StepState } from "$lib/protocol";

  // One inline timeline: chat bubbles + the workflow events (status/debug/approval)
  // rendered in place, instead of a separate workflow pane.
  type ChatItem =
    | { kind: "user" | "assistant"; id: string; text: string }
    | { kind: "status"; id: string; stepId: string; label: string; state: StepState; detail?: string }
    | { kind: "debug"; id: string; title: string; body: string; language?: string }
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
  let view = $state<"chat" | "vault">("chat");
  // Run-queue position — shown as a floating bottom-right badge, not inline.
  let queueMsg = $state<string | null>(null);

  // Intro disclaimer shown when the demo starts. Remembered per browser session so a
  // reload within the same tab doesn't nag, but every new visitor sees it once.
  const INTRO_KEY = "millfolio-demo-intro-dismissed";
  let showIntro = $state(false);
  onMount(() => {
    try {
      showIntro = sessionStorage.getItem(INTRO_KEY) !== "1";
    } catch {
      showIntro = true; // sessionStorage unavailable (private mode etc.) — still show it
    }
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
      case "debug":
        items.push({ kind: "debug", id: uid(), title: e.title, body: e.body, language: e.language });
        break;
      case "message":
        // NB: the server stamps every message with id "msg" (events.mojo), so two
        // identical answers (same cached program → same reply) would collide on the
        // {#each items (it.id)} key and Svelte would silently drop the 2nd — the
        // classic "2nd question hangs". Key on a fresh unique id, not the server's.
        items.push({ kind: "assistant", id: uid(), text: e.text });
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

<div class="version" title="build">{__APP_VERSION__}</div>

<main>
  <header class="topbar">
    <div class="brand">
      <img class="brand-logo" src="/favicon.svg" alt="" width="22" height="22" />
      {brandName}
    </div>
    <nav class="tabs">
      <button class:active={view === "chat"} onclick={() => (view = "chat")}>Chat</button>
      <button class:active={view === "vault"} onclick={() => (view = "vault")}>Vault</button>
    </nav>
  </header>
  <div class="single">
    {#if view === "chat"}
      <ChatPanel {items} {busy} demo={isDemo} onsend={send} onapprove={approve} onreject={reject} />
    {:else}
      <VaultPanel />
    {/if}
  </div>
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
    display: flex;
    align-items: center;
    gap: 8px;
    font-weight: 700;
    letter-spacing: 0.02em;
  }
  .brand-logo {
    width: 22px;
    height: 22px;
    border-radius: 5px;
    display: block;
  }
  .tabs {
    display: flex;
    gap: 4px;
  }
  .tabs button {
    padding: 5px 12px;
    border-radius: var(--radius);
    border: 1px solid transparent;
    background: transparent;
    color: var(--text-dim);
    font-weight: 600;
    font-size: 13px;
  }
  .tabs button:hover {
    color: var(--text);
  }
  .tabs button.active {
    background: var(--surface-2);
    border-color: var(--border);
    color: var(--text);
  }
  .single {
    flex: 1;
    min-height: 0;
    display: grid;
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
    bottom: 16px;
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
    .queue-badge { right: 8px; bottom: 8px; font-size: 12px; }
  }
  .version {
    position: fixed;
    left: 8px;
    bottom: 6px;
    z-index: 30;
    font-size: 11px;
    color: var(--text-dim);
    opacity: 0.6;
    font-variant-numeric: tabular-nums;
    pointer-events: none;
    user-select: none;
  }
</style>
