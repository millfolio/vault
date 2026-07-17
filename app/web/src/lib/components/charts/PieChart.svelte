<script lang="ts">
  // Pie/donut chart for a SHARE-OF-WHOLE breakdown (COMPUTE_VS_RENDER Phase 2) — a
  // total split across a SMALL number of named parts (≤ ~8; many parts → bar/table).
  // Hand-rolled inline SVG, no lib, no CDN. Each slice is sized by its money `raw`;
  // the LEGEND pairs a color swatch with the label + exact money() `text` + the
  // computed % (identity is never color-alone). Colors cycle the validated
  // categorical palette (--chart-1..8). Every string renders via {expr} so Svelte
  // auto-escapes it — the spec is untrusted sandbox data.
  import type { ResultValue } from "$lib/protocol";
  import { pieArcs, donutSector } from "./chartUtil";

  let {
    title,
    slices,
    labelHref,
  }: {
    title: string;
    slices: { label: string; value: ResultValue }[];
    // When set, each slice + its legend label links into the filtered Vault view
    // (e.g. /vault?merchant=…). Absent → plain, non-clickable labels.
    labelHref?: (label: string) => string;
  } = $props();

  const HUES = [
    "var(--chart-1)",
    "var(--chart-2)",
    "var(--chart-3)",
    "var(--chart-4)",
    "var(--chart-5)",
    "var(--chart-6)",
    "var(--chart-7)",
    "var(--chart-8)",
  ];

  // Geometry: a centered donut in a square-ish viewBox.
  const VB = { W: 260, H: 260 };
  const CX = VB.W / 2;
  const CY = VB.H / 2;
  const R = 110;
  const RI = 62; // donut hole

  function valRaw(v: ResultValue): number {
    return v && (v.type === "money" || v.type === "count") ? v.raw : 0;
  }
  function valText(v: ResultValue): string {
    if (v == null) return "";
    return v.type === "money" || v.type === "count" ? v.text : v.value;
  }

  const raws = $derived(slices.map((s) => valRaw(s.value)));
  const arcs = $derived(pieArcs(raws));
  const total = $derived(raws.reduce((s, v) => (isFinite(v) && v > 0 ? s + v : s), 0));
  const drawable = $derived(slices.length > 0 && total > 0);

  function pct(frac: number): string {
    return (frac * 100).toFixed(frac >= 0.1 ? 0 : 1) + "%";
  }
</script>

<figure class="chart">
  {#if title}<figcaption>{title}</figcaption>{/if}

  {#if !drawable}
    <p class="empty">No data to chart.</p>
  {:else}
    <div class="wrap">
      <svg
        class="pie"
        viewBox="0 0 {VB.W} {VB.H}"
        preserveAspectRatio="xMidYMid meet"
        role="img"
        aria-label={`Pie chart: ${title || "breakdown"}, ${slices.length} parts`}
      >
        {#each arcs as a, i}
          {#if a.frac > 0}
            {#if labelHref}
              <a class="hit" href={labelHref(slices[i].label)} aria-label={`${slices[i].label}: ${valText(slices[i].value)} — show in Vault`}>
                <path
                  class="slice"
                  style="fill:{HUES[i % HUES.length]}"
                  d={donutSector(CX, CY, R, RI, a.a0, a.a1)}
                >
                  <title>{slices[i].label}: {valText(slices[i].value)} ({pct(a.frac)}) — show in Vault</title>
                </path>
              </a>
            {:else}
              <path
                class="slice"
                style="fill:{HUES[i % HUES.length]}"
                d={donutSector(CX, CY, R, RI, a.a0, a.a1)}
              >
                <title>{slices[i].label}: {valText(slices[i].value)} ({pct(a.frac)})</title>
              </path>
            {/if}
          {/if}
        {/each}
      </svg>

      <!-- legend: identity is never color-alone (swatch + label + value + %) -->
      <ul class="legend">
        {#each slices as s, i}
          <li class="key">
            <span class="sw" style="background:{HUES[i % HUES.length]}"></span>
            {#if labelHref}
              <a class="lbl link" href={labelHref(s.label)} title="Show these records in the Vault">{s.label}</a>
            {:else}
              <span class="lbl">{s.label}</span>
            {/if}
            <span class="val">{valText(s.value)}</span>
            <span class="pct">{pct(arcs[i]?.frac ?? 0)}</span>
          </li>
        {/each}
      </ul>
    </div>
  {/if}

  <details class="data">
    <summary>Show data</summary>
    <table>
      <thead><tr><th>Part</th><th>Amount</th><th>Share</th></tr></thead>
      <tbody>
        {#each slices as s, i}
          <tr>
            <td>{s.label}</td>
            <td class="num">{valText(s.value)}</td>
            <td class="num">{pct(arcs[i]?.frac ?? 0)}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  </details>
</figure>

<style>
  .chart {
    margin: 0;
    max-width: 100%;
  }
  figcaption {
    font-size: 12px;
    color: var(--text-dim);
    margin-bottom: 2px;
  }
  .empty {
    font-size: 12px;
    color: var(--text-dim);
    margin: 4px 0;
  }
  .wrap {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 16px;
  }
  .pie {
    width: 200px;
    max-width: 100%;
    height: auto;
    display: block;
    overflow: visible;
    font-family: var(--sans);
    flex: 0 0 auto;
  }
  .slice {
    stroke: var(--surface);
    stroke-width: 1.5;
  }
  .hit {
    cursor: pointer;
  }
  .hit:hover .slice {
    opacity: 0.85;
  }
  a.lbl.link {
    color: var(--text);
    text-decoration: underline;
    text-decoration-style: dotted;
    text-underline-offset: 2px;
    cursor: pointer;
  }
  a.lbl.link:hover {
    color: var(--accent, var(--text));
    text-decoration-style: solid;
  }
  .legend {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 5px;
    min-width: 0;
    flex: 1 1 160px;
  }
  .key {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: var(--text-dim);
  }
  .sw {
    width: 10px;
    height: 10px;
    border-radius: 2px;
    display: inline-block;
    flex: 0 0 auto;
  }
  .lbl {
    color: var(--text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1 1 auto;
    min-width: 0;
  }
  .val {
    font-variant-numeric: tabular-nums;
    flex: 0 0 auto;
  }
  .pct {
    font-variant-numeric: tabular-nums;
    min-width: 3ch;
    text-align: right;
    flex: 0 0 auto;
  }
  .data {
    margin-top: 6px;
    font-size: 12px;
    color: var(--text-dim);
  }
  .data summary {
    cursor: pointer;
    user-select: none;
  }
  .data table {
    border-collapse: collapse;
    margin-top: 4px;
  }
  .data th,
  .data td {
    padding: 3px 10px 3px 0;
    text-align: left;
  }
  .data td.num {
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
</style>
