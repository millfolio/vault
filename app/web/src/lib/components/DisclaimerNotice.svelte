<script lang="ts">
  import { onMount } from "svelte";
  import DisclaimerContent from "./DisclaimerContent.svelte";

  // First-run liability/privacy notice — a dismissible modal shown ONCE per browser
  // (localStorage flag). Real install only; the caller guards it out of the public
  // demo, which has its own "About this demo" intro. After dismissal it stays
  // reachable via the persistent link in Operations → Logs.
  const ACK_KEY = "millfolio.disclaimerAck";
  let show = $state(false);

  onMount(() => {
    try {
      show = localStorage.getItem(ACK_KEY) !== "1";
    } catch {
      // localStorage unavailable (private mode etc.) — still show it, just can't
      // remember the dismissal.
      show = true;
    }
  });

  function acknowledge() {
    show = false;
    try {
      localStorage.setItem(ACK_KEY, "1");
    } catch {}
  }
</script>

{#if show}
  <div class="disc-backdrop" role="presentation">
    <div
      class="disc-card"
      role="dialog"
      aria-modal="true"
      aria-labelledby="disclaimer-title"
      tabindex="-1"
    >
      <DisclaimerContent heading="h2" />
      <div class="disc-actions">
        <button class="disc-ok" onclick={acknowledge}>I understand</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .disc-backdrop {
    position: fixed;
    inset: 0;
    z-index: 60;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 20px;
    background: rgba(0, 0, 0, 0.55);
  }
  .disc-card {
    max-width: 520px;
    width: 100%;
    max-height: calc(100vh - 40px);
    overflow-y: auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 22px 24px;
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.4);
  }
  .disc-actions {
    display: flex;
    justify-content: flex-end;
    margin-top: 16px;
  }
  .disc-ok {
    padding: 8px 18px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    background: var(--accent);
    color: #00132e;
    font-weight: 600;
    font-size: 13px;
    cursor: pointer;
  }
  .disc-ok:hover {
    filter: brightness(1.08);
  }
</style>
