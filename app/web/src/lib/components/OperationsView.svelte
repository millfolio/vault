<script lang="ts">
  // Operations — the machine-activity view, with a Files|Records-style sub-tab switch
  // (the same SubTabs control the Vault tab uses):
  //   Operations — Now / Controls / History / System / Backfill (the live machine state)
  //   Stats      — per-question timing
  //   Logs       — where the vault data + log files live on disk
  // The parent ([[tab]]/+page.svelte) picks the initial sub-tab from the URL
  // (/operations|/system → operations, /stats → stats) and re-keys this component so
  // a fresh instance captures a new initial value; clicking a sub-tab is internal
  // state (no URL change) — exactly how VaultPanel's Records|Tags|Files switch works.
  import { untrack } from "svelte";
  import SubTabs from "./SubTabs.svelte";
  import OperationsPanel from "./OperationsPanel.svelte";
  import StatsPanel from "./StatsPanel.svelte";
  import LogsPanel from "./LogsPanel.svelte";

  let {
    demo = false,
    initialSub = "operations",
  }: { demo?: boolean; initialSub?: string } = $props();

  const TABS = [
    { id: "operations", label: "Operations" },
    { id: "stats", label: "Stats" },
    { id: "logs", label: "Logs" },
  ];
  // Capture the route's initial sub-tab once; the parent re-keys this component when the
  // route changes (/operations vs /stats), so a fresh initial value arrives with a new
  // instance (mirrors the old SystemPanel wrapper).
  let sub = $state(
    untrack(() => (initialSub === "stats" || initialSub === "logs" ? initialSub : "operations")),
  );
</script>

<section class="opsview">
  <div class="head">
    <SubTabs tabs={TABS} active={sub} onselect={(id) => (sub = id)} />
  </div>
  <div class="pane">
    {#if sub === "stats"}
      <StatsPanel />
    {:else if sub === "logs"}
      <LogsPanel {demo} />
    {:else}
      <OperationsPanel {demo} />
    {/if}
  </div>
</section>

<style>
  .opsview {
    display: flex;
    flex-direction: column;
    min-height: 0;
    flex: 1;
  }
  .head {
    padding: 14px 16px 0;
    max-width: 820px;
    margin: 0 auto;
    width: 100%;
  }
  /* Grid (like the top-level .single) so the active sub-panel stretches to fill
     both axes — the panels expect to be a stretched grid/flex child. */
  .pane {
    flex: 1;
    min-height: 0;
    display: grid;
  }
</style>
