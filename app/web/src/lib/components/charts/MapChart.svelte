<script lang="ts">
  // Offline BUBBLE MAP (proportional-symbol map) for the `map` result block. A place
  // (ISO-3166 alpha-3 country, or US 2-letter state) gets a circle at its centroid,
  // its AREA ∝ the money value (never radius ∝ value — that over-reads big places).
  // Hand-rolled inline SVG over a BUNDLED low-res outline — no map lib, tiles, CDN,
  // or remote GeoJSON (the app is offline/self-contained, same as the other charts).
  // dataviz proportional-symbol spec: recessive geography, one hue at partial opacity
  // so overlaps read, a nested-circle SIZE legend, sparing direct labels on the top
  // few, every bubble carries its exact money() `text` as a tooltip + in the table.
  import type { ResultValue } from "$lib/protocol";
  import { geoFor, type XY } from "./mapData";

  let {
    title,
    level,
    points,
  }: {
    title: string;
    level: "country" | "state";
    points: { code: string; value: ResultValue }[];
  } = $props();

  const geo = $derived(geoFor(level));

  // viewBox: width fixed, height derived from the projection aspect so geography
  // isn't stretched. A small pad keeps edge outlines off the frame.
  const W = 680;
  const PAD = 10;
  const H = $derived(Math.round(W / geo.aspect));
  function px(p: XY): [number, number] {
    return [PAD + p[0] * (W - 2 * PAD), PAD + p[1] * (H - 2 * PAD)];
  }
  function ring(r: XY[]): string {
    return r.map((p, i) => `${i === 0 ? "M" : "L"}${px(p).map((n) => n.toFixed(1)).join(",")}`).join(" ") + " Z";
  }

  function rawOf(v: ResultValue): number {
    return v && (v.type === "money" || v.type === "count") ? Math.abs(v.raw) : 0;
  }
  function textOf(v: ResultValue): string {
    if (!v) return "";
    return v.type === "money" || v.type === "count" ? v.text : v.value;
  }

  interface Bubble {
    code: string;
    name: string;
    raw: number;
    text: string;
    pos: XY; // normalized
    r: number; // viewBox units
  }

  const R_MIN = 5;
  const R_MAX = 30;

  // Split into mappable (a known centroid) and unmapped (dropped from the map, still
  // listed in the table). Largest drawn first so small bubbles land on top.
  const prepared = $derived.by(() => {
    const mapped: { code: string; name: string; raw: number; text: string; pos: XY }[] = [];
    const unmapped: { code: string; name: string; text: string }[] = [];
    for (const p of points ?? []) {
      const code = (p.code ?? "").toUpperCase();
      const pos = geo.centroids[code];
      const name = geo.names[code] ?? code;
      const text = textOf(p.value);
      if (pos) mapped.push({ code, name, raw: rawOf(p.value), text, pos });
      else unmapped.push({ code, name, text });
    }
    const maxRaw = mapped.reduce((m, d) => Math.max(m, d.raw), 0);
    const bubbles: Bubble[] = mapped
      .map((d) => {
        const frac = maxRaw > 0 ? Math.sqrt(d.raw / maxRaw) : 0; // area ∝ value
        const r = maxRaw > 0 ? Math.max(R_MIN, Math.min(R_MAX, R_MAX * frac)) : R_MIN;
        return { ...d, r };
      })
      .sort((a, b) => b.raw - a.raw);
    return { bubbles, unmapped, maxRaw };
  });

  const bubbles = $derived(prepared.bubbles);
  // Direct-label only the top few (dataviz: label sparingly — the rest ride tooltips).
  const LABEL_TOP = 3;
  const maxBubble = $derived(bubbles[0]);
</script>

{#if (points?.length ?? 0) > 0}
  <figure class="map">
    {#if title}<figcaption>{title}</figcaption>{/if}

    {#if bubbles.length > 0}
      <!-- size legend: two nested reference circles (proportional-symbol convention) -->
      <div class="legend" aria-hidden="true">
        <svg class="legsvg" viewBox="0 0 {R_MAX * 2 + 2} {R_MAX * 2 + 2}">
          <circle class="legcircle" cx={R_MAX + 1} cy={R_MAX * 2 + 1 - R_MAX} r={R_MAX} />
          <circle class="legcircle" cx={R_MAX + 1} cy={R_MAX * 2 + 1 - R_MAX / 2} r={R_MAX / 2} />
        </svg>
        <span class="legtext">
          Bubble area ∝ amount{#if maxBubble} · max {maxBubble.text}{/if}
        </span>
      </div>

      <svg
        viewBox="0 0 {W} {H}"
        preserveAspectRatio="xMidYMid meet"
        role="img"
        aria-label={`Bubble map: ${title || "amounts"} by ${level}, ${bubbles.length} place${bubbles.length === 1 ? "" : "s"}`}
      >
        <!-- recessive geography -->
        {#each geo.outline as r}
          <path class="land" d={ring(r)} />
        {/each}

        <!-- proportional-symbol bubbles (semi-transparent so overlaps read) -->
        {#each bubbles as b (b.code)}
          {@const c = px(b.pos)}
          <circle class="bubble" cx={c[0]} cy={c[1]} r={b.r}>
            <title>{b.name}: {b.text}</title>
          </circle>
        {/each}

        <!-- sparing direct labels on the top few -->
        {#each bubbles.slice(0, LABEL_TOP) as b (b.code)}
          {@const c = px(b.pos)}
          <text class="blabel" x={c[0]} y={c[1] - b.r - 3} text-anchor="middle">{b.code}</text>
        {/each}
      </svg>
    {:else}
      <!-- no mappable places → the table IS the view -->
      <p class="nomap">No mappable {level === "state" ? "states" : "countries"} — showing the data as a table.</p>
    {/if}

    <!-- table view (a11y relief + the fallback; every place, mapped or not) -->
    <details class="data" open={bubbles.length === 0}>
      <summary>Show data</summary>
      <table>
        <thead><tr><th>Place</th><th>Code</th><th>Amount</th></tr></thead>
        <tbody>
          {#each bubbles as b (b.code)}
            <tr><td>{b.name}</td><td>{b.code}</td><td class="num">{b.text}</td></tr>
          {/each}
          {#each prepared.unmapped as u (u.code)}
            <tr class="unmapped"><td>{u.name}</td><td>{u.code}</td><td class="num">{u.text}</td></tr>
          {/each}
        </tbody>
      </table>
      {#if prepared.unmapped.length > 0}
        <p class="note">{prepared.unmapped.length} place{prepared.unmapped.length === 1 ? "" : "s"} not on the map (unknown code).</p>
      {/if}
    </details>
  </figure>
{/if}

<style>
  .map {
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
    align-items: flex-end;
    gap: 8px;
    margin-bottom: 4px;
  }
  .legsvg {
    width: 34px;
    height: 34px;
    overflow: visible;
  }
  .legcircle {
    fill: none;
    stroke: var(--text-dim);
    stroke-width: 1;
    opacity: 0.7;
  }
  .legtext {
    font-size: 11.5px;
    color: var(--text-dim);
  }
  svg {
    width: 100%;
    height: auto;
    display: block;
    overflow: visible;
    font-family: var(--sans);
  }
  .land {
    fill: var(--surface-2);
    stroke: var(--border);
    stroke-width: 1;
    stroke-linejoin: round;
  }
  .bubble {
    fill: var(--chart-1);
    fill-opacity: 0.5;
    stroke: var(--chart-1);
    stroke-width: 1.5;
  }
  .blabel {
    fill: var(--text);
    font-size: 11px;
    font-weight: 600;
    paint-order: stroke;
    stroke: var(--surface);
    stroke-width: 3;
    stroke-linejoin: round;
  }
  .nomap {
    font-size: 12.5px;
    color: var(--text-dim);
    margin: 6px 0;
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
  .data tr.unmapped td {
    opacity: 0.7;
  }
  .note {
    margin: 4px 0 0;
    font-size: 11px;
    color: var(--text-dim);
  }
</style>
