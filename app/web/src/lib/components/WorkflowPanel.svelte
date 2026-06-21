<script lang="ts">
  import type { StepState } from "$lib/protocol";

  export interface DebugEntry {
    title: string;
    body: string;
    language?: string;
  }
  export interface Step {
    id: string;
    label: string;
    state: StepState;
    detail?: string;
    debug: DebugEntry[];
    approval?: { title: string; body: string; language?: string };
  }

  let {
    steps,
    onapprove,
    onreject,
  }: {
    steps: Step[];
    onapprove: (stepId: string) => void;
    onreject: (stepId: string) => void;
  } = $props();

  const icon: Record<StepState, string> = {
    pending: "○",
    running: "◐",
    "awaiting-approval": "⏸",
    done: "●",
    error: "✕",
  };
</script>

<section class="workflow">
  <div class="steps">
    {#if steps.length === 0}
      <p class="empty">Steps, approvals, and debug detail appear here as millfolio works.</p>
    {/if}

    {#each steps as step (step.id)}
      <div class="step {step.state}">
        <div class="row">
          <span class="icon" aria-hidden="true">{icon[step.state]}</span>
          <span class="label">{step.label}</span>
        </div>
        {#if step.detail}<p class="detail">{step.detail}</p>{/if}

        {#if step.state === "awaiting-approval" && step.approval}
          <div class="approval">
            <p class="atitle">{step.approval.title}</p>
            <pre><code>{step.approval.body}</code></pre>
            <div class="actions">
              <button class="approve" onclick={() => onapprove(step.id)}>Approve</button>
              <button class="reject" onclick={() => onreject(step.id)}>Reject</button>
            </div>
          </div>
        {/if}

        {#each step.debug as d (d.title)}
          <details>
            <summary>{d.title}</summary>
            <pre><code>{d.body}</code></pre>
          </details>
        {/each}
      </div>
    {/each}
  </div>
</section>

<style>
  .workflow {
    display: flex;
    flex-direction: column;
    min-height: 0;
    background: var(--bg);
    border-left: 1px solid var(--border);
  }
  .steps {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .empty {
    color: var(--text-dim);
  }
  .step {
    padding: 10px 12px;
    border: 1px solid var(--border);
    border-radius: var(--radius);
    background: var(--surface);
  }
  .row {
    display: flex;
    gap: 10px;
    align-items: center;
  }
  .icon {
    width: 1em;
    text-align: center;
  }
  .step.running .icon { color: var(--accent); }
  .step.done .icon { color: var(--ok); }
  .step.error .icon { color: var(--err); }
  .step.awaiting-approval .icon { color: var(--warn); }
  .label { font-weight: 500; }
  .detail {
    margin: 6px 0 0;
    color: var(--text-dim);
    font-size: 12.5px;
  }
  .approval {
    margin-top: 10px;
    padding: 10px;
    border: 1px solid var(--warn);
    border-radius: var(--radius);
    background: var(--surface-2);
  }
  .atitle { margin: 0 0 8px; color: var(--warn); }
  .actions { display: flex; gap: 8px; margin-top: 8px; }
  .actions button {
    padding: 6px 14px;
    border-radius: var(--radius);
    border: none;
    font-weight: 600;
  }
  .approve { background: var(--ok); color: #06120a; }
  .reject { background: transparent; color: var(--text-dim); border: 1px solid var(--border) !important; }
  details {
    margin-top: 8px;
    border-top: 1px solid var(--border);
    padding-top: 8px;
  }
  summary {
    cursor: pointer;
    color: var(--text-dim);
    font-size: 12px;
  }
  pre {
    margin: 8px 0 0;
    padding: 10px;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow-x: auto;
  }
</style>
