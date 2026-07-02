<script lang="ts">
  // System — the operator/diagnostics tab. Collapses what used to be the separate
  // Stats and System tabs into one, with a Files|Records-style sub-tab switch:
  //   Backfill — AI-tag backfill progress + controls
  //   Stats           — per-question timing
  //   Logs            — data + log file locations
  import { untrack } from "svelte";
  import SubTabs from "./SubTabs.svelte";
  import BackfillPanel from "./BackfillPanel.svelte";
  import StatsPanel from "./StatsPanel.svelte";
  import LogsPanel from "./LogsPanel.svelte";

  let {
    demo = false,
    initialSub = "backfill",
  }: { demo?: boolean; initialSub?: string } = $props();

  const TABS = [
    { id: "backfill", label: "Backfill" },
    { id: "stats", label: "Stats" },
    { id: "logs", label: "Logs" },
  ];
  // Capture the route's initial sub-tab once; the parent remounts this component
  // when the top-level route changes (/system vs /stats), so a fresh initial value
  // arrives with a new instance.
  let sub = $state(untrack(() => initialSub));
</script>

<section class="sys">
  <div class="head">
    <SubTabs tabs={TABS} active={sub} onselect={(id) => (sub = id)} />
  </div>
  <div class="pane">
    {#if sub === "backfill"}
      <BackfillPanel {demo} standalone />
    {:else if sub === "stats"}
      <StatsPanel />
    {:else}
      <LogsPanel {demo} />
    {/if}
  </div>
</section>

<style>
  .sys {
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
