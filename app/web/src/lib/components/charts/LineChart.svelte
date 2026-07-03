<script lang="ts">
  // Line chart for a TIME series (COMPUTE_VS_RENDER Phase 2). Hand-rolled inline
  // SVG — no charting lib, no CDN. One measure = one hue (--chart-1), so no legend;
  // the title names the series. Money AXIS scales by `raw`; tick labels are compact
  // currency; each point's tooltip carries the exact money() `text`. dataviz mark
  // specs: 2px line, ≥8px end markers with a 2px surface ring, hairline grid.
  import {
    LAYOUT,
    plotW,
    plotH,
    moneyDomain,
    moneyTick,
    currencySymbol,
    labelStride,
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

  function x(i: number): number {
    if (n <= 1) return LAYOUT.ml + plotW / 2;
    return LAYOUT.ml + (plotW * i) / (n - 1);
  }
  function y(v: number): number {
    const { lo, hi } = dom;
    const f = hi === lo ? 0 : (v - lo) / (hi - lo);
    return LAYOUT.mt + plotH * (1 - f);
  }
  const baseline = $derived(y(0));
  const linePoints = $derived(raw.map((v, i) => `${x(i)},${y(v)}`).join(" "));
  const areaPath = $derived(
    n === 0
      ? ""
      : `M${x(0)},${baseline} ` +
          raw.map((v, i) => `L${x(i)},${y(v)}`).join(" ") +
          ` L${x(n - 1)},${baseline} Z`,
  );
</script>

<figure class="chart">
  {#if title}<figcaption>{title}</figcaption>{/if}
  <svg
    viewBox="0 0 {LAYOUT.W} {LAYOUT.H}"
    preserveAspectRatio="xMidYMid meet"
    role="img"
    aria-label={`Line chart: ${title || "series"}, ${n} points`}
  >
    <!-- y gridlines + tick labels (clean currency; recessive hairlines) -->
    {#each dom.ticks as t}
      <line class="grid" x1={LAYOUT.ml} y1={y(t)} x2={LAYOUT.W - LAYOUT.mr} y2={y(t)} />
      <text class="ytick" x={LAYOUT.ml - 8} y={y(t) + 3} text-anchor="end">{moneyTick(t, sym)}</text>
    {/each}
    <!-- baseline (zero) drawn a touch stronger -->
    <line class="axis" x1={LAYOUT.ml} y1={baseline} x2={LAYOUT.W - LAYOUT.mr} y2={baseline} />

    {#if n >= 2}
      <path class="area" d={areaPath} />
      <polyline class="line" points={linePoints} />
    {/if}

    <!-- x labels (sparse to avoid collisions) -->
    {#each xValues as xv, i}
      {#if i % stride === 0 || i === n - 1}
        <text class="xtick" x={x(i)} y={LAYOUT.H - 12} text-anchor="middle">{xv}</text>
      {/if}
    {/each}

    <!-- markers with a surface ring; each carries the exact money text as a tooltip -->
    {#each raw as v, i}
      <circle class="ring" cx={x(i)} cy={y(v)} r="5.5" />
      <circle class="dot" cx={x(i)} cy={y(v)} r="3.5">
        <title>{xValues[i]}: {text[i]}</title>
      </circle>
    {/each}
  </svg>

  <!-- table view (accessibility relief + the non-chart fallback) -->
  <details class="data">
    <summary>Show data</summary>
    <table>
      <thead><tr><th>Point</th><th>Amount</th></tr></thead>
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
  .area {
    fill: var(--chart-1);
    opacity: 0.1;
  }
  .line {
    fill: none;
    stroke: var(--chart-1);
    stroke-width: 2;
    stroke-linejoin: round;
    stroke-linecap: round;
  }
  .dot {
    fill: var(--chart-1);
  }
  .ring {
    fill: var(--surface);
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
