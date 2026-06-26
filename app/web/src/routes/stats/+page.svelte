<script lang="ts">
  // Stats is primarily a tab on the main page (Chat / Vault / Stats). This route keeps
  // the /stats URL working as a deep link — same panel, with a back link to Chat.
  import StatsPanel from "$lib/components/StatsPanel.svelte";
</script>

<svelte:head><title>Stats</title></svelte:head>

<main>
  <header class="topbar">
    <a class="back" href="/">← Chat</a>
    <h1>Usage stats</h1>
  </header>
  <StatsPanel />
</main>

<style>
  main {
    min-height: 100vh;
    min-height: 100dvh;
    display: flex;
    flex-direction: column;
  }
  .topbar {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
  }
  .topbar h1 {
    margin: 0;
    font-size: 15px;
    font-weight: 700;
  }
  .back {
    color: var(--text-dim);
    text-decoration: none;
    font-weight: 600;
    font-size: 13px;
  }
  .back:hover {
    color: var(--accent);
  }
</style>
