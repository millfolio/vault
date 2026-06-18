<script lang="ts">
  import ChatPanel from "$lib/components/ChatPanel.svelte";
  import WorkflowPanel, { type Step } from "$lib/components/WorkflowPanel.svelte";
  import { createMockClient } from "$lib/client";
  import type { ServerEvent, Session } from "$lib/protocol";

  interface ChatMessage {
    id: string;
    role: "user" | "assistant";
    text: string;
  }

  const client = createMockClient();

  let messages = $state<ChatMessage[]>([]);
  let steps = $state<Step[]>([]);
  let busy = $state(false);
  let session: Session | undefined;

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
  <div class="brand">veilens</div>
  <div class="panes">
    <ChatPanel {messages} {busy} onsend={send} />
    <WorkflowPanel {steps} onapprove={approve} onreject={reject} />
  </div>
</main>

<style>
  main {
    height: 100vh;
    display: flex;
    flex-direction: column;
  }
  .brand {
    padding: 10px 16px;
    font-weight: 700;
    letter-spacing: 0.02em;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
  }
  .panes {
    flex: 1;
    min-height: 0;
    display: grid;
    grid-template-columns: 1fr 1fr;
  }
  @media (max-width: 800px) {
    .panes {
      grid-template-columns: 1fr;
      grid-template-rows: 1fr 1fr;
    }
  }
</style>
