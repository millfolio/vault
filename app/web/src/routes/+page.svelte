<script lang="ts">
  import ChatPanel from "$lib/components/ChatPanel.svelte";
  import WorkflowPanel, { type Step } from "$lib/components/WorkflowPanel.svelte";
  import VaultPanel from "$lib/components/VaultPanel.svelte";
  import { createMockClient } from "$lib/client";
  import { createWsClient } from "$lib/wsClient";
  import type { ServerEvent, Session, MillfolioClient } from "$lib/protocol";

  interface ChatMessage {
    id: string;
    role: "user" | "assistant";
    text: string;
  }

  // Transport selection:
  //  - explicit ?server=ws://… wins (any host/port);
  //  - else when served locally by millfolio-server (:10000), open the WS on the
  //    SAME origin (one port now serves HTTP + WS; flare upgrades the request);
  //  - else (e.g. `npm run dev` on :5173) fall back to the in-browser mock.
  function pickClient(): MillfolioClient {
    if (typeof location === "undefined") return createMockClient();
    const explicit = new URLSearchParams(location.search).get("server");
    if (explicit) return createWsClient(explicit);
    if (location.port === "10000") {
      const scheme = location.protocol === "https:" ? "wss" : "ws";
      return createWsClient(`${scheme}://${location.host}/chat`);
    }
    return createMockClient();
  }
  const client = pickClient();

  let messages = $state<ChatMessage[]>([]);
  let steps = $state<Step[]>([]);
  let busy = $state(false);
  let session: Session | undefined;
  let view = $state<"chat" | "vault">("chat");

  function upsertStep(id: string, patch: Partial<Step>) {
    const i = steps.findIndex((s) => s.id === id);
    if (i === -1) {
      steps.push({ id, label: patch.label ?? id, state: patch.state ?? "pending", debug: [], ...patch });
    } else {
      steps[i] = { ...steps[i], ...patch };
    }
  }

  function handle(e: ServerEvent) {
    switch (e.type) {
      case "status":
        upsertStep(e.stepId, { label: e.label, state: e.state, detail: e.detail });
        if (e.state === "awaiting-approval") busy = false; // hand control to the user
        break;
      case "approval-request":
        upsertStep(e.stepId, { approval: e.payload });
        break;
      case "debug": {
        const s = steps.find((x) => x.id === e.stepId);
        if (s) s.debug = [...s.debug, { title: e.title, body: e.body, language: e.language }];
        break;
      }
      case "message":
        messages.push({ id: e.id, role: "assistant", text: e.text });
        busy = false;
        break;
      case "error":
        messages.push({ id: crypto.randomUUID(), role: "assistant", text: `Error: ${e.message}` });
        busy = false;
        break;
    }
  }

  function send(text: string) {
    messages.push({ id: crypto.randomUUID(), role: "user", text });
    steps = [];
    busy = true;
    session = client.ask(text, handle);
  }

  function approve(stepId: string) {
    busy = true;
    session?.approve(stepId);
  }
  function reject(stepId: string) {
    session?.reject(stepId, "rejected by user");
  }
</script>

<main>
  <header class="topbar">
    <div class="brand">millfolio</div>
    <nav class="tabs">
      <button class:active={view === "chat"} onclick={() => (view = "chat")}>Chat</button>
      <button class:active={view === "vault"} onclick={() => (view = "vault")}>Vault</button>
    </nav>
  </header>
  {#if view === "chat"}
    <div class="panes">
      <ChatPanel {messages} {busy} onsend={send} />
      <WorkflowPanel {steps} onapprove={approve} onreject={reject} />
    </div>
  {:else}
    <div class="single">
      <VaultPanel />
    </div>
  {/if}
</main>

<style>
  main {
    height: 100vh;
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
  .panes {
    flex: 1;
    min-height: 0;
    display: grid;
    grid-template-columns: 1fr 1fr;
  }
  .single {
    flex: 1;
    min-height: 0;
    display: grid;
  }
  @media (max-width: 800px) {
    .panes {
      grid-template-columns: 1fr;
      grid-template-rows: 1fr 1fr;
    }
  }
</style>
