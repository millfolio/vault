<script lang="ts">
  import { onMount } from "svelte";

  // One usage record per answered question, written by the server (server.mojo
  // _append_stats) and returned verbatim by /api/stats. `api` is the per-category
  // breakdown: [name, callCount, totalMs] — the same categories the live "Stats:" line
  // shows (alias / codegen / compile / fix / the vault tools).
  type Rec = {
    ts: number;
    q: string;
    model: string;
    ok: boolean;
    total_ms: number;
    prefill_tok: number;
    gen_tok: number;
    prefill_ms: number;
    decode_ms: number;
    api: [string, number, number][];
  };

  let model = $state("");
  let records = $state<Rec[]>([]);
  let loaded = $state(false);
  let failed = $state(false);

  onMount(() => {
    fetch("/api/stats")
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((d) => {
        model = typeof d?.model === "string" ? d.model : "";
        records = Array.isArray(d?.records) ? d.records : [];
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
    // Per-category: aggregate over the questions that USED each category, so a
    // category's average reflects the questions it actually appears in (transaction
    // questions and document questions exercise different tools).
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

  // Most recent first — the last 10 usages.
  const recent = $derived([...records].slice(-10).reverse());
</script>

<svelte:head><title>Stats</title></svelte:head>

<main>
  <header class="topbar">
    <a class="back" href="/">← Chat</a>
    <h1>Usage stats</h1>
    {#if model}<span class="model"><span class="dot" aria-hidden="true"></span>{model}</span>{/if}
  </header>

  <div class="body">
    {#if !loaded}
      <p class="muted">Loading…</p>
    {:else if failed}
      <p class="muted">Couldn't load stats (is the server running?).</p>
    {:else if !stats}
      <p class="muted">No questions answered yet — ask one on the <a href="/">Chat</a> page.</p>
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
            <tr><th>When</th><th>Question</th><th class="r">Time</th><th class="r">Tokens (pf / gen)</th><th>Model</th></tr>
          </thead>
          <tbody>
            {#each recent as r (r.ts + r.q)}
              <tr>
                <td class="muted nowrap">{fmtTime(r.ts)}</td>
                <td class="q">{r.q}{#if !r.ok}<span class="bad"> (stopped)</span>{/if}</td>
                <td class="r nowrap">{fmtMs(r.total_ms)}</td>
                <td class="r nowrap muted">{r.prefill_tok} / {r.gen_tok}</td>
                <td class="muted">{r.model}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </div>
</main>

<style>
  main {
    min-height: 100vh;
    min-height: 100dvh;
    display: flex;
    flex-direction: column;
  }
  .topbar {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
  }
  .topbar h1 {
    margin: 0;
    font-size: 15px;
    font-weight: 700;
  }
  .back {
    color: var(--text-dim);
    text-decoration: none;
    font-weight: 600;
    font-size: 13px;
  }
  .back:hover {
    color: var(--accent);
  }
  .model {
    margin-left: auto;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: var(--text);
    font-weight: 600;
    font-size: 13px;
    font-variant-numeric: tabular-nums;
  }
  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent);
  }
  .body {
    flex: 1;
    padding: 20px 16px 40px;
    max-width: 860px;
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
    margin-bottom: 28px;
  }
  .card {
    background: var(--surface);
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
    margin: 24px 0 10px;
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
    white-space: normal;
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
  a {
    color: var(--accent);
  }
</style>
