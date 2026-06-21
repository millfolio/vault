<script lang="ts">
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
    if (location.port === "10000") {
      const scheme = location.protocol === "https:" ? "wss" : "ws";
      return createWsClient(`${scheme}://${location.host}/chat`);
    }
    return createMockClient();
  }
  const client = pickClient();

  let items = $state<ChatItem[]>([]);
  let busy = $state(false);
  let session: Session | undefined;
  let view = $state<"chat" | "vault">("chat");

  function handle(e: ServerEvent) {
    switch (e.type) {
      case "status": {
        // Update the status line in place (keyed by stepId), else append it inline.
        const i = items.findIndex((x) => x.kind === "status" && x.stepId === e.stepId);
        if (i === -1) {
          items.push({ kind: "status", id: crypto.randomUUID(), stepId: e.stepId, label: e.label, state: e.state, detail: e.detail });
        } else {
          items[i] = { ...items[i], label: e.label, state: e.state, detail: e.detail };
        }
        if (e.state === "awaiting-approval") busy = false; // hand control to the user
        break;
      }
      case "approval-request":
        items.push({ kind: "approval", id: crypto.randomUUID(), stepId: e.stepId, title: e.payload.title, body: e.payload.body, language: e.payload.language });
        break;
      case "debug":
        items.push({ kind: "debug", id: crypto.randomUUID(), title: e.title, body: e.body, language: e.language });
        break;
      case "message":
        items.push({ kind: "assistant", id: e.id, text: e.text });
        busy = false;
        break;
      case "error":
        items.push({ kind: "assistant", id: crypto.randomUUID(), text: `Error: ${e.message}` });
        busy = false;
        break;
    }
  }

  function send(text: string) {
    items.push({ kind: "user", id: crypto.randomUUID(), text });
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

<main>
  <header class="topbar">
    <div class="brand">millfolio</div>
    <nav class="tabs">
      <button class:active={view === "chat"} onclick={() => (view = "chat")}>Chat</button>
      <button class:active={view === "vault"} onclick={() => (view = "vault")}>Vault</button>
    </nav>
  </header>
  <div class="single">
    {#if view === "chat"}
      <ChatPanel {items} {busy} onsend={send} onapprove={approve} onreject={reject} />
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
  .single {
    flex: 1;
    min-height: 0;
    display: grid;
  }
</style>
