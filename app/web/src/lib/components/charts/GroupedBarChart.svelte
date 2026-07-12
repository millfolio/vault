<script lang="ts">
  // Grouped bar chart — two category series sharing an x-axis (the form heuristic's
  // "two grouped categories"). Hand-rolled inline SVG. Two measures = two hues from
  // the validated pair (--chart-1/--chart-2) WITH a legend, plus a 2px surface gap
  // between adjacent bars (secondary encoding, per dataviz). Money AXIS by `raw`;
  // ticks compact currency; each sub-bar's tooltip carries the exact money() `text`.
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
    xcats,
    series,
  }: {
    title: string;
    xcats: string[];
    series: { title: string; raw: number[]; text: string[] }[];
  } = $props();

  const HUES = ["var(--chart-1)", "var(--chart-2)"];
  const n = $derived(xcats.length);
  const k = $derived(series.length);
  const allRaw = $derived(series.flatMap((s) => s.raw));
  const dom = $derived(moneyDomain(allRaw));
  const sym = $derived(currencySymbol(series[0]?.text[0]));
  const stride = $derived(labelStride(n));
  const band = $derived(n > 0 ? plotW / n : plotW);
  const groupW = $derived(Math.min(band * 0.72, k * 26));
  const subW = $derived(Math.max(3, groupW / Math.max(1, k) - 2)); // 2px surface gap

  function groupX(i: number): number {
    return LAYOUT.ml + band * i + band / 2 - groupW / 2;
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
  <!-- legend: identity is never color-alone (swatch + name) -->
  <div class="legend">
    {#each series as s, si}
      <span class="key"><span class="sw" style="background:{HUES[si % HUES.length]}"></span>{s.title}</span>
    {/each}
  </div>
  <svg
    viewBox="0 0 {LAYOUT.W} {LAYOUT.H}"
    preserveAspectRatio="xMidYMid meet"
    role="img"
    aria-label={`Grouped bar chart: ${title || "series"}, ${n} categories × ${k} series`}
  >
    {#each dom.ticks as t}
      <line class="grid" x1={LAYOUT.ml} y1={y(t)} x2={LAYOUT.W - LAYOUT.mr} y2={y(t)} />
      <text class="ytick" x={LAYOUT.ml - 8} y={y(t) + 3} text-anchor="end">{moneyTick(t, sym)}</text>
    {/each}
    <line class="axis" x1={LAYOUT.ml} y1={baseline} x2={LAYOUT.W - LAYOUT.mr} y2={baseline} />

    {#each xcats as cat, i}
      {#each series as s, si}
        <path
          class="bar"
          style="fill:{HUES[si % HUES.length]}"
          d={barPath(groupX(i) + si * (subW + 2), subW, baseline, y(s.raw[i] ?? 0))}
        >
          <title>{cat} · {s.title}: {s.text[i] ?? ""}</title>
        </path>
      {/each}
      {#if i % stride === 0 || i === n - 1}
        <text class="xtick" x={LAYOUT.ml + band * i + band / 2} y={LAYOUT.H - 12} text-anchor="middle">{cat}</text>
      {/if}
    {/each}
  </svg>

  <details class="data">
    <summary>Show data</summary>
    <table>
      <thead>
        <tr><th>Category</th>{#each series as s}<th>{s.title}</th>{/each}</tr>
      </thead>
      <tbody>
        {#each xcats as cat, i}
          <tr><td>{cat}</td>{#each series as s}<td class="num">{s.text[i] ?? ""}</td>{/each}</tr>
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
  .legend {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    margin-bottom: 4px;
  }
  .key {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 11.5px;
    color: var(--text-dim);
  }
  .sw {
    width: 10px;
    height: 10px;
    border-radius: 2px;
    display: inline-block;
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
