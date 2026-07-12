<script lang="ts">
  // Bar chart for a CATEGORY series (COMPUTE_VS_RENDER Phase 2). Hand-rolled inline
  // SVG. One measure = one hue (--chart-1), no legend. dataviz bar spec: ≤24px thick
  // (capped, air in the band), 4px rounded data-end square at the baseline. Money
  // AXIS scales by `raw`; ticks are compact currency; each bar's tooltip + (when few)
  // its cap label carry the exact money() `text` — never a bare float.
  import {
    LAYOUT,
    plotW,
    plotH,
    moneyDomain,
    moneyTick,
    currencySymbol,
    labelStride,
    barPath,
  } from "./chartUtil";

  let {
    title,
    xValues,
    raw,
    text,
  }: { title: string; xValues: string[]; raw: number[]; text: string[] } = $props();

  const n = $derived(xValues.length);
  const dom = $derived(moneyDomain(raw));
  const sym = $derived(currencySymbol(text[0]));
  const stride = $derived(labelStride(n));
  const band = $derived(n > 0 ? plotW / n : plotW);
  const barW = $derived(Math.min(24, band * 0.62));

  function cx(i: number): number {
    return LAYOUT.ml + band * i + band / 2;
  }
  function y(v: number): number {
    const { lo, hi } = dom;
    const f = hi === lo ? 0 : (v - lo) / (hi - lo);
    return LAYOUT.mt + plotH * (1 - f);
  }
  const baseline = $derived(y(0));
</script>

<figure class="chart">
  {#if title}<figcaption>{title}</figcaption>{/if}
  <svg
    viewBox="0 0 {LAYOUT.W} {LAYOUT.H}"
    preserveAspectRatio="xMidYMid meet"
    role="img"
    aria-label={`Bar chart: ${title || "series"}, ${n} categories`}
  >
    {#each dom.ticks as t}
      <line class="grid" x1={LAYOUT.ml} y1={y(t)} x2={LAYOUT.W - LAYOUT.mr} y2={y(t)} />
      <text class="ytick" x={LAYOUT.ml - 8} y={y(t) + 3} text-anchor="end">{moneyTick(t, sym)}</text>
    {/each}
    <line class="axis" x1={LAYOUT.ml} y1={baseline} x2={LAYOUT.W - LAYOUT.mr} y2={baseline} />

    {#each raw as v, i}
      <path class="bar" d={barPath(cx(i) - barW / 2, barW, baseline, y(v))}>
        <title>{xValues[i]}: {text[i]}</title>
      </path>
      {#if n <= 8}
        <text class="cap" x={cx(i)} y={Math.min(y(v), baseline) - 5} text-anchor="middle">{text[i]}</text>
      {/if}
      {#if i % stride === 0 || i === n - 1}
        <text class="xtick" x={cx(i)} y={LAYOUT.H - 12} text-anchor="middle">{xValues[i]}</text>
      {/if}
    {/each}
  </svg>

  <details class="data">
    <summary>Show data</summary>
    <table>
      <thead><tr><th>Category</th><th>Amount</th></tr></thead>
      <tbody>
        {#each xValues as xv, i}<tr><td>{xv}</td><td class="num">{text[i]}</td></tr>{/each}
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
  svg {
    width: 100%;
    height: auto;
    display: block;
    overflow: visible;
    font-family: var(--sans);
  }
  .grid {
    stroke: var(--border);
    stroke-width: 1;
  }
  .axis {
    stroke: var(--text-dim);
    stroke-width: 1;
    opacity: 0.5;
  }
  .ytick,
  .xtick {
    fill: var(--text-dim);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }
  .cap {
    fill: var(--text-dim);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }
  .bar {
    fill: var(--chart-1);
  }
  .data {
    margin-top: 4px;
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
