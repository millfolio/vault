<script lang="ts">
  import { onMount } from "svelte";

  // One usage record per answered question, written by the server (server.mojo
  // _append_stats) and returned verbatim by /api/stats. `api` is the per-category
  // breakdown: [name, callCount, totalMs] — the same categories the live "Stats:" line
  // shows (alias / codegen / compile / fix / the vault tools). `version` is the build
  // that answered it (matches the bottom-bar stamp) → averages per deployed version.
  type Rec = {
    ts: number;
    q: string;
    model: string;
    version?: string;
    ok: boolean;
    total_ms: number;
    prefill_tok: number;
    gen_tok: number;
    prefill_ms: number;
    decode_ms: number;
    api: [string, number, number][];
  };

  // The build currently serving this page (vite define) — to highlight the live row.
  const CURRENT = typeof __APP_VERSION__ !== "undefined" ? __APP_VERSION__ : "";

  // Cumulative ML-tag backfill dedup savings: identical transaction descriptions
  // (recurring charges) are classified once, not per row. saved = seen - classified.
  type Backfill = { rows_seen: number; rows_classified: number; saved: number };

  let model = $state("");
  let records = $state<Rec[]>([]);
  let backfill = $state<Backfill | null>(null);
  let loaded = $state(false);
  let failed = $state(false);

  // Same-origin in production; an explicit ?api=… wins; Vite dev (:5173) has no backend.
  function apiBase(): string {
    if (typeof location === "undefined") return "";
    const explicit = new URLSearchParams(location.search).get("api");
    if (explicit) return explicit.replace(/\/$/, "");
    return "";
  }

  onMount(() => {
    fetch(`${apiBase()}/api/stats`)
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((d) => {
        model = typeof d?.model === "string" ? d.model : "";
        records = Array.isArray(d?.records) ? d.records : [];
        backfill =
          d?.backfill && typeof d.backfill.rows_seen === "number" ? d.backfill : null;
        loaded = true;
      })
      .catch(() => {
        failed = true;
        loaded = true;
      });
  });

  function fmtMs(ms: number): string {
    if (!isFinite(ms)) return "—";
    return ms < 1000 ? `${Math.round(ms)}ms` : `${(ms / 1000).toFixed(1)}s`;
  }
  function fmtTime(ts: number): string {
    try {
      return new Date(ts * 1000).toLocaleString();
    } catch {
      return "";
    }
  }
  function rate(n: number, ms: number): number {
    return ms > 0 ? Math.round((n * 1000) / ms) : 0;
  }

  // Averages over ALL recorded questions (the "per question" summary at the top).
  const stats = $derived.by(() => {
    const r = records;
    const N = r.length;
    if (!N) return null;
    const sum = (f: (x: Rec) => number) => r.reduce((a, x) => a + (f(x) || 0), 0);
    const sumPfTok = sum((x) => x.prefill_tok),
      sumPfMs = sum((x) => x.prefill_ms);
    const sumGenTok = sum((x) => x.gen_tok),
      sumGenMs = sum((x) => x.decode_ms);
    const cat = new Map<string, { q: number; count: number; ms: number }>();
    for (const x of r)
      for (const [name, count, ms] of x.api || []) {
        const c = cat.get(name) || { q: 0, count: 0, ms: 0 };
        c.q += 1;
        c.count += count || 0;
        c.ms += ms || 0;
        cat.set(name, c);
      }
    const cats = [...cat.entries()]
      .map(([name, c]) => ({ name, q: c.q, avgCount: c.count / c.q, avgMs: c.ms / c.q }))
      .sort((a, b) => b.avgMs - a.avgMs);
    return {
      N,
      avgTotal: sum((x) => x.total_ms) / N,
      avgPfTok: Math.round(sumPfTok / N),
      avgGenTok: Math.round(sumGenTok / N),
      pfRate: rate(sumPfTok, sumPfMs),
      genRate: rate(sumGenTok, sumGenMs),
      cats,
    };
  });

  // Averages grouped by deployed build version, most-recently-used first.
  const byVersion = $derived.by(() => {
    const m = new Map<string, { n: number; totalMs: number; genTok: number; genMs: number; lastTs: number }>();
    for (const x of records) {
      const v = x.version || "unknown";
      const c = m.get(v) || { n: 0, totalMs: 0, genTok: 0, genMs: 0, lastTs: 0 };
      c.n += 1;
      c.totalMs += x.total_ms || 0;
      c.genTok += x.gen_tok || 0;
      c.genMs += x.decode_ms || 0;
      if ((x.ts || 0) > c.lastTs) c.lastTs = x.ts || 0;
      m.set(v, c);
    }
    return [...m.entries()]
      .map(([version, c]) => ({
        version,
        n: c.n,
        avgMs: c.totalMs / c.n,
        genRate: rate(c.genTok, c.genMs),
        lastTs: c.lastTs,
      }))
      .sort((a, b) => b.lastTs - a.lastTs);
  });

  // Most recent first — the last 10 usages.
  const recent = $derived([...records].slice(-10).reverse());
</script>

<section class="statspanel">
  <div class="body">
    {#if !loaded}
      <p class="muted">Loading…</p>
    {:else if failed}
      <p class="muted">Couldn't load stats (is the server running?).</p>
    {:else if !stats}
      <p class="muted">No questions answered yet — ask one on the Chat tab.</p>
    {:else}
      <section class="cards">
        <div class="card">
          <div class="num">{stats.N}</div>
          <div class="cap">questions answered</div>
        </div>
        <div class="card">
          <div class="num">{fmtMs(stats.avgTotal)}</div>
          <div class="cap">avg time / question</div>
        </div>
        <div class="card">
          <div class="num">{stats.genRate}<span class="unit"> tok/s</span></div>
          <div class="cap">avg generation speed</div>
        </div>
        <div class="card">
          <div class="num">{stats.avgPfTok}<span class="sep"> / </span>{stats.avgGenTok}</div>
          <div class="cap">avg tokens (prefill / gen)</div>
        </div>
      </section>

      {#if backfill && backfill.rows_seen > 0}
        <h2>AI-tag backfill dedup</h2>
        <section class="cards">
          <div class="card">
            <div class="num">{backfill.saved.toLocaleString()}</div>
            <div class="cap">classifications skipped (duplicate descriptions)</div>
          </div>
          <div class="card">
            <div class="num">{Math.round((backfill.saved / backfill.rows_seen) * 100)}<span class="unit">%</span></div>
            <div class="cap">of {backfill.rows_seen.toLocaleString()} rows were duplicates</div>
          </div>
          <div class="card">
            <div class="num">{backfill.rows_classified.toLocaleString()}</div>
            <div class="cap">distinct descriptions classified</div>
          </div>
        </section>
      {/if}

      <h2>Average per deployed version</h2>
      <div class="tablewrap">
        <table>
          <thead>
            <tr><th>Version</th><th class="r">Questions</th><th class="r">Avg time</th><th class="r">Gen speed</th></tr>
          </thead>
          <tbody>
            {#each byVersion as v (v.version)}
              <tr class:live={v.version === CURRENT}>
                <td class="nowrap">{v.version}{#if v.version === CURRENT}<span class="livetag"> live</span>{/if}</td>
                <td class="r">{v.n}</td>
                <td class="r">{fmtMs(v.avgMs)}</td>
                <td class="r">{v.genRate} tok/s</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>

      <h2>Average per question, by step</h2>
      <div class="tablewrap">
        <table>
          <thead>
            <tr><th>Step</th><th class="r">Avg calls</th><th class="r">Avg time</th><th class="r">Seen in</th></tr>
          </thead>
          <tbody>
            {#each stats.cats as c (c.name)}
              <tr>
                <td>{c.name}</td>
                <td class="r">{c.avgCount.toFixed(c.avgCount >= 10 ? 0 : 1)}</td>
                <td class="r">{fmtMs(c.avgMs)}</td>
                <td class="r muted">{c.q}/{stats.N}</td>
              </tr>
            {/each}
            {#if stats.pfRate > 0 || stats.genRate > 0}
              <tr class="modelrow">
                <td>model (prefill / gen)</td>
                <td class="r">{stats.avgPfTok} / {stats.avgGenTok} tok</td>
                <td class="r">{stats.pfRate} / {stats.genRate} tok/s</td>
                <td class="r muted"></td>
              </tr>
            {/if}
          </tbody>
        </table>
      </div>

      <h2>Last 10 usages</h2>
      <div class="tablewrap">
        <table>
          <thead>
            <tr><th>When</th><th>Question</th><th class="r">Time</th><th class="r">Tokens (pf / gen)</th><th>Version</th></tr>
          </thead>
          <tbody>
            {#each recent as r (r.ts + r.q)}
              <tr>
                <td class="muted nowrap">{fmtTime(r.ts)}</td>
                <td class="q">{r.q}{#if !r.ok}<span class="bad"> (stopped)</span>{/if}</td>
                <td class="r nowrap">{fmtMs(r.total_ms)}</td>
                <td class="r nowrap muted">{r.prefill_tok} / {r.gen_tok}</td>
                <td class="muted nowrap">{r.version ?? "—"}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </div>
</section>

<style>
  .statspanel {
    display: flex;
    flex-direction: column;
    min-height: 0;
    background: var(--surface);
  }
  .body {
    flex: 1;
    overflow-y: auto;
    padding: 20px 16px 40px;
    max-width: 880px;
    width: 100%;
    margin: 0 auto;
  }
  .muted {
    color: var(--text-dim);
  }
  .cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
    gap: 12px;
    margin-bottom: 8px;
  }
  .card {
    background: var(--surface-2);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 16px 18px;
  }
  .card .num {
    font-size: 26px;
    font-weight: 700;
    color: var(--text);
    font-variant-numeric: tabular-nums;
  }
  .card .num .unit,
  .card .num .sep {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-dim);
  }
  .card .cap {
    margin-top: 4px;
    font-size: 12px;
    color: var(--text-dim);
  }
  h2 {
    font-size: 13px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text-dim);
    margin: 26px 0 10px;
  }
  .tablewrap {
    overflow-x: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius);
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }
  th,
  td {
    padding: 8px 12px;
    text-align: left;
    border-bottom: 1px solid var(--border);
  }
  thead th {
    color: var(--text-dim);
    font-weight: 600;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    background: var(--surface);
  }
  tbody tr:last-child td {
    border-bottom: none;
  }
  td.r,
  th.r {
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
  .nowrap {
    white-space: nowrap;
  }
  .q {
    color: var(--text);
  }
  .bad {
    color: #e0833a;
  }
  .modelrow td {
    color: var(--text);
  }
  tr.live td {
    background: color-mix(in srgb, var(--accent) 10%, transparent);
  }
  .livetag {
    color: var(--accent);
    font-weight: 700;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
</style>
