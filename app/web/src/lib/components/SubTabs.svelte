<script lang="ts">
  // A small segmented sub-tab switch — the Files | Records control under Vault,
  // reused for Backfill | Stats | Logs under System. Purely presentational:
  // the parent owns the active id and gets a callback on change.
  type Tab = { id: string; label: string };
  let {
    tabs,
    active,
    onselect,
  }: { tabs: Tab[]; active: string; onselect: (id: string) => void } = $props();
</script>

<div class="subtabs" role="tablist">
  {#each tabs as t}
    <button
      role="tab"
      aria-selected={active === t.id}
      class:active={active === t.id}
      onclick={() => onselect(t.id)}
    >
      {t.label}
    </button>
  {/each}
</div>

<style>
  .subtabs {
    display: inline-flex;
    gap: 2px;
    padding: 2px;
    margin-bottom: 14px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--surface-2);
  }
  .subtabs button {
    border: none;
    background: transparent;
    color: var(--text-dim);
    font: inherit;
    font-size: 12.5px;
    font-weight: 600;
    padding: 5px 14px;
    border-radius: calc(var(--radius) - 2px);
    cursor: pointer;
  }
  .subtabs button.active {
    background: var(--accent);
    color: #06101f;
  }
</style>
