<script lang="ts">
  // The deterministic RESULT-SPEC presenter (COMPUTE_VS_RENDER Phase 2). Renders the
  // typed data a generated program emitted BELOW its text bubble, choosing the MARK
  // from the data's SHAPE (the dataviz form heuristic) — the CLIENT picks the view,
  // not the model:
  //   single number (kpi block)          → KPI tile
  //   series, time (x = date)            → line chart
  //   series, category                   → bar chart
  //   two category series sharing an x   → grouped bar chart
  //   table block / anything odd / empty → table  (graceful fallback)
  // An optional `hint` ("line"/"bar"/"grouped-bar") overrides the default when set.
  // Charts are hand-rolled inline SVG (no lib, no CDN); money AXES scale by `raw`,
  // labels use the exact money() `text`. Every string is rendered via {expr} so
  // Svelte auto-escapes it — NEVER {@html} (the spec is untrusted sandbox data).
  import type { ResultSpec, ResultValue, ResultBlock, EntityKind } from "$lib/protocol";
  import LineChart from "$lib/components/charts/LineChart.svelte";
  import BarChart from "$lib/components/charts/BarChart.svelte";
  import GroupedBarChart from "$lib/components/charts/GroupedBarChart.svelte";
  import MapChart from "$lib/components/charts/MapChart.svelte";
  import PieChart from "$lib/components/charts/PieChart.svelte";
  import ResultTable from "$lib/components/ResultTable.svelte";

  let { result }: { result: ResultSpec } = $props();

  type SeriesBlock = Extract<ResultBlock, { kind: "series" }>;
  type Unit =
    | { t: "kpi"; label: string; value: ResultValue }
    | { t: "table"; headers: string[]; rows: ResultValue[][]; entities: (EntityKind | null)[] }
    | { t: "chart"; mark: "line" | "bar"; title: string; x: string[]; raw: number[]; text: string[]; entity: EntityKind | null }
    | { t: "group"; title: string; xcats: string[]; series: { title: string; raw: number[]; text: string[] }[] }
    | { t: "map"; level: "country" | "state" | "city"; title: string; points: { code: string; value: ResultValue; label?: string }[] }
    | { t: "pie"; title: string; slices: { label: string; value: ResultValue }[]; entity: EntityKind | null };

  // The mark for ONE series, from its shape (+ optional hint override).
  function markFor(s: SeriesBlock): "line" | "bar" {
    if (s.hint === "line") return "line";
    if (s.hint === "bar") return "bar";
    return s.seriesKind === "time" ? "line" : "bar";
  }
  // Two category series with the SAME x categories → a grouped bar (the form
  // heuristic's "two grouped categories"). Capped at 2 (the validated hue pair).
  function groupable(a: ResultBlock, b: ResultBlock | undefined): b is SeriesBlock {
    return (
      !!b &&
      a.kind === "series" &&
      b.kind === "series" &&
      a.seriesKind === "category" &&
      b.seriesKind === "category" &&
      a.x.values.length > 0 &&
      JSON.stringify(a.x.values) === JSON.stringify(b.x.values)
    );
  }

  function toUnits(blocks: ResultBlock[]): Unit[] {
    const out: Unit[] = [];
    for (let i = 0; i < blocks.length; i++) {
      const b = blocks[i];
      if (b.kind === "kpi") {
        out.push({ t: "kpi", label: b.label, value: b.value });
      } else if (b.kind === "table") {
        out.push({
          t: "table",
          headers: b.headers,
          rows: b.rows,
          // Example/preview data must not deep-link: its values are synthetic
          // ("WHOLE FOODS" from the seed) and won't exist in the user's vault.
          entities: result.preview
            ? b.headers.map(() => null)
            : colEntities(b.headers, b.entities),
        });
      } else if (b.kind === "map") {
        if ((b.points?.length ?? 0) > 0) out.push({ t: "map", level: b.level, title: b.title, points: b.points });
      } else if (b.kind === "pie") {
        out.push({
          t: "pie",
          title: b.title,
          slices: b.slices ?? [],
          entity: result.preview ? null : entityForCategory(undefined, b.title),
        });
      } else {
        // series
        if (b.x.values.length === 0) continue; // empty → nothing to draw
        const next = blocks[i + 1];
        if (groupable(b, next)) {
          out.push({
            t: "group",
            title: b.title || next.title,
            xcats: b.x.values,
            series: [
              { title: b.title || "Series 1", raw: b.y.raw, text: b.y.text },
              { title: next.title || "Series 2", raw: next.y.raw, text: next.y.text },
            ],
          });
          i++; // consumed the pair
        } else {
          // Only a CATEGORY axis (bar) links its labels; a time axis (line) has
          // dates, not entities. Preview data never deep-links (synthetic values).
          const entity =
            !result.preview && b.seriesKind === "category"
              ? entityForCategory(b.x.entity, b.title)
              : null;
          out.push({ t: "chart", mark: markFor(b), title: b.title, x: b.x.values, raw: b.y.raw, text: b.y.text, entity });
        }
      }
    }
    return out;
  }

  // Graceful fallback: an unknown contract version → render nothing (the text bubble
  // already carries the answer). Same for a data-less (text-only) spec.
  const units = $derived(result?.v === 1 ? toUnits(result.data ?? []) : []);

  /** Per-column entity: the spec's explicit `entities` wins; else fall back
   *  to the header NAME so widgets saved before the field existed become
   *  clickable without regeneration. */
  function colEntities(
    headers: string[],
    entities?: (EntityKind | null)[],
  ): (EntityKind | null)[] {
    return headers.map((h, i) => {
      const e = entities?.[i];
      if (e === "merchant" || e === "tag" || e === "month") return e;
      const n = h.trim().toLowerCase();
      if (n === "merchant") return "merchant";
      if (n === "tag" || n === "tags") return "tag";
      if (n === "month") return "month";
      return null;
    });
  }

  /** Entity kind for a CATEGORY chart axis: the spec's explicit `x.entity` wins,
   *  else infer from the block TITLE so charts saved before the field existed
   *  become clickable without regeneration. Conservative — only the known words. */
  function entityForCategory(
    explicit: EntityKind | null | undefined,
    title: string,
  ): EntityKind | null {
    if (explicit === "merchant" || explicit === "tag" || explicit === "month") return explicit;
    const t = (title || "").toLowerCase();
    if (/\bmerchants?\b/.test(t)) return "merchant";
    if (/\btags?\b/.test(t)) return "tag";
    if (/\bmonths?\b/.test(t)) return "month";
    return null;
  }

  /** A chart-label → Vault-filter href builder, passed to the chart so it can turn
   *  category labels into links. Undefined when the axis carries no entity (labels
   *  stay plain text). The label IS the normalized entity string. */
  function labelHrefFor(entity: EntityKind | null): ((label: string) => string) | undefined {
    if (!entity) return undefined;
    return (label: string) => `/vault?${entity}=${encodeURIComponent(label)}`;
  }

  function cellText(v: ResultValue): string {
    if (v == null) return "";
    if (v.type === "money" || v.type === "count") return v.text;
    return v.value;
  }
</script>

{#if units.length > 0}
  <div class="result">
    {#each units as u (u)}
      {#if u.t === "kpi"}
        <div class="kpi">
          <span class="kpi-label">{u.label}</span>
          <span class="kpi-value">{cellText(u.value)}</span>
        </div>
      {:else if u.t === "table"}
        <ResultTable headers={u.headers} rows={u.rows} entities={u.entities} />
      {:else if u.t === "group"}
        <GroupedBarChart title={u.title} xcats={u.xcats} series={u.series} />
      {:else if u.t === "map"}
        <MapChart title={u.title} level={u.level} points={u.points} />
      {:else if u.t === "pie"}
        <PieChart title={u.title} slices={u.slices} labelHref={labelHrefFor(u.entity)} />
      {:else if u.mark === "line"}
        <LineChart title={u.title} xValues={u.x} raw={u.raw} text={u.text} />
      {:else}
        <BarChart title={u.title} xValues={u.x} raw={u.raw} text={u.text} labelHref={labelHrefFor(u.entity)} />
      {/if}
    {/each}
  </div>
{/if}

<style>
  .result {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: 6px;
    max-width: 100%;
  }
  /* KPI tile */
  .kpi {
    display: inline-flex;
    flex-direction: column;
    gap: 2px;
    align-self: flex-start;
    padding: 8px 14px;
    border-radius: var(--radius);
    background: var(--surface-2);
    border: 1px solid var(--border, rgba(127, 127, 127, 0.18));
  }
  .kpi-label {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-dim);
  }
  .kpi-value {
    font-size: 20px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }
  /* table rendering (+ filters, footer total, deep-links) lives in ResultTable */
</style>
