<script lang="ts">
  // Offline BUBBLE MAP (proportional-symbol map) for the `map` result block. A place
  // (ISO-3166 alpha-3 country, US 2-letter state, or — level "city" — a US zip) gets
  // a circle at its centroid, its AREA ∝ the money value (never radius ∝ value — that
  // over-reads big places). Hand-rolled inline SVG over a BUNDLED low-res outline — no
  // map lib, tiles, CDN, or remote GeoJSON (the app is offline/self-contained, same as
  // the other charts). CITY maps place each bubble by its `.zip`'s gazetteer centroid
  // (clean + exact) and LABEL it by the program-provided `.city` name — the messy
  // descriptor city name never has to match a gazetteer. The zip table (~0.9 MB) is
  // LAZILY loaded, only when a city map first renders, so it never bloats other views.
  // dataviz proportional-symbol spec: recessive geography, one hue at partial opacity
  // so overlaps read, a nested-circle SIZE legend, sparing direct labels on the top
  // few, every bubble carries its exact money() `text` as a tooltip + in the table.
  import type { ResultValue } from "$lib/protocol";
  import {
    geoFor,
    CITY_GEO,
    projectUS,
    loadZipCentroids,
    titleCaseCity,
    type XY,
    type ZipTable,
  } from "./mapData";

  let {
    title,
    level,
    points,
  }: {
    title: string;
    level: "country" | "state" | "city";
    points: { code: string; value: ResultValue; label?: string }[];
  } = $props();

  // Country/state carry a bundled centroid+outline table; a city map reuses the US
  // (state) box's outline + aspect and places bubbles from the lazily-loaded zips.
  const geo = $derived(level === "city" ? CITY_GEO : geoFor(level));

  // Lazily-loaded zip → [lat, lon] gazetteer; `null` until the first city map loads it.
  let zipData = $state<ZipTable | null>(null);
  $effect(() => {
    if (level === "city" && zipData === null) {
      loadZipCentroids().then((t) => (zipData = t));
    }
  });
  const cityLoading = $derived(level === "city" && zipData === null);

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
    name: string; // full place name (tooltip + table)
    tag: string; // short direct-label for the top-few (code, or city name)
    raw: number;
    text: string;
    pos: XY; // normalized
    r: number; // viewBox units
  }

  const R_MIN = 5;
  const R_MAX = 30;

  function clamp01(n: number): number {
    return n < 0 ? 0 : n > 1 ? 1 : n;
  }

  // Placement + display for one point, level-aware:
  //   country/state → bundled centroid table, keyed by the (upper-cased) code.
  //   city          → look the point's `.zip` up in the gazetteer → project by the
  //                   US box; label by the program-provided `.city` name.
  // Returns `null` for `pos` when the code/zip has no known centroid (→ unmapped).
  function placeOf(p: { code: string; value: ResultValue; label?: string }): {
    code: string;
    name: string;
    tag: string;
    pos: XY | null;
  } {
    if (level === "city") {
      const zip = (p.code ?? "").trim();
      const label = (p.label ?? "").trim();
      const name = label ? titleCaseCity(label) : zip;
      const ll = zipData ? zipData[zip] : undefined;
      if (ll) {
        const xy = projectUS(ll[0], ll[1]);
        return { code: zip, name, tag: name, pos: [clamp01(xy[0]), clamp01(xy[1])] };
      }
      return { code: zip, name, tag: name, pos: null };
    }
    const code = (p.code ?? "").toUpperCase();
    return { code, name: geo.names[code] ?? code, tag: code, pos: geo.centroids[code] ?? null };
  }

  // Split into mappable (a known centroid) and unmapped (dropped from the map, still
  // listed in the table). Largest drawn first so small bubbles land on top. While a
  // city map's zip table is still loading, hold everything back (no premature drops).
  const prepared = $derived.by(() => {
    const mapped: { code: string; name: string; tag: string; raw: number; text: string; pos: XY }[] = [];
    const unmapped: { code: string; name: string; text: string }[] = [];
    if (!cityLoading) {
      for (const p of points ?? []) {
        const { code, name, tag, pos } = placeOf(p);
        const text = textOf(p.value);
        if (pos) mapped.push({ code, name, tag, raw: rawOf(p.value), text, pos });
        else unmapped.push({ code, name, text });
      }
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

  // Count (don't silently drop) points whose zip isn't in the gazetteer.
  $effect(() => {
    if (level === "city" && !cityLoading && prepared.unmapped.length > 0) {
      console.warn(`MapChart: ${prepared.unmapped.length} city point(s) had no mappable zip.`);
    }
  });
  // Direct-label only the top few (dataviz: label sparingly — the rest ride tooltips).
  const LABEL_TOP = 3;
  const maxBubble = $derived(bubbles[0]);

  // Level-aware wording for the fallback line, table header, and unmapped note.
  const placeWord = $derived(level === "city" ? "cities" : level === "state" ? "states" : "countries");
  const codeHeader = $derived(level === "city" ? "Zip" : "Code");
  const dropWord = $derived(level === "city" ? "zip" : "code");
  // Stable per-place key (a city's modal zip is ~unique, but pair with the name so a
  // rare shared zip can't collide the keyed-each).
  const keyOf = (code: string, name: string) => `${code}|${name}`;
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
        {#each bubbles as b (keyOf(b.code, b.name))}
          {@const c = px(b.pos)}
          <circle class="bubble" cx={c[0]} cy={c[1]} r={b.r}>
            <title>{b.name}: {b.text}</title>
          </circle>
        {/each}

        <!-- sparing direct labels on the top few -->
        {#each bubbles.slice(0, LABEL_TOP) as b (keyOf(b.code, b.name))}
          {@const c = px(b.pos)}
          <text class="blabel" x={c[0]} y={c[1] - b.r - 3} text-anchor="middle">{b.tag}</text>
        {/each}
      </svg>
    {:else if cityLoading}
      <!-- city map: zip gazetteer still loading (lazy-loaded on first city render) -->
      <p class="nomap">Loading map…</p>
    {:else}
      <!-- no mappable places → the table IS the view -->
      <p class="nomap">No mappable {placeWord} — showing the data as a table.</p>
    {/if}

    <!-- table view (a11y relief + the fallback; every place, mapped or not) -->
    <details class="data" open={bubbles.length === 0}>
      <summary>Show data</summary>
      <table>
        <thead><tr><th>Place</th><th>{codeHeader}</th><th>Amount</th></tr></thead>
        <tbody>
          {#each bubbles as b (keyOf(b.code, b.name))}
            <tr><td>{b.name}</td><td>{b.code}</td><td class="num">{b.text}</td></tr>
          {/each}
          {#each prepared.unmapped as u (keyOf(u.code, u.name))}
            <tr class="unmapped"><td>{u.name}</td><td>{u.code}</td><td class="num">{u.text}</td></tr>
          {/each}
        </tbody>
      </table>
      {#if prepared.unmapped.length > 0}
        <p class="note">{prepared.unmapped.length} place{prepared.unmapped.length === 1 ? "" : "s"} not on the map (unknown {dropWord}).</p>
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
