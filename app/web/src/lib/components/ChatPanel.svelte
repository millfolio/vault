<script lang="ts">
  interface ChatMessage {
    id: string;
    role: "user" | "assistant";
    text: string;
  }

  let {
    messages,
    busy,
    onsend,
  }: {
    messages: ChatMessage[];
    busy: boolean;
    onsend: (text: string) => void;
  } = $props();

  let draft = $state("");

  function submit(e: SubmitEvent) {
    e.preventDefault();
    const text = draft.trim();
    if (!text || busy) return;
    onsend(text);
    draft = "";
  }
</script>

<section class="chat">
  <div class="messages">
    {#if messages.length === 0}
      <p class="empty">Ask a question about your vault.</p>
    {/if}
    {#each messages as m (m.id)}
      <div class="msg {m.role}">
        <span class="who">{m.role === "user" ? "you" : "millfolio"}</span>
        <p>{m.text}</p>
      </div>
    {/each}
  </div>

  <form onsubmit={submit}>
    <input
      type="text"
      placeholder="Ask your vault…"
      bind:value={draft}
      disabled={busy}
    />
    <button type="submit" disabled={busy || !draft.trim()}>Send</button>
  </form>
</section>

<style>
  .chat {
    display: flex;
    flex-direction: column;
    min-height: 0;
    background: var(--surface);
  }
  .messages {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .empty {
    color: var(--text-dim);
    margin: auto;
  }
  .msg {
    max-width: 80%;
  }
  .msg.user {
    align-self: flex-end;
    text-align: right;
  }
  .who {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-dim);
  }
  .msg p {
    margin: 2px 0 0;
    padding: 8px 12px;
    border-radius: var(--radius);
    background: var(--surface-2);
  }
  .msg.user p {
    background: var(--accent-dim);
  }
  form {
    display: flex;
    gap: 8px;
    padding: 12px;
    border-top: 1px solid var(--border);
  }
  input {
    flex: 1;
    padding: 9px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
  }
  input:focus {
    outline: none;
    border-color: var(--accent);
  }
  button {
    padding: 9px 16px;
    border-radius: var(--radius);
    border: none;
    background: var(--accent);
    color: #06101f;
    font-weight: 600;
  }
  button:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
</style>
