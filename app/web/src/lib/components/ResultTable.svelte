<script lang="ts">
  // A rendered result TABLE with client-side smarts (no re-query): per-column
  // filters (amount range, date range, description contains), a footer TOTAL that
  // recomputes over the filtered rows, and description cells that deep-link into
  // the Vault. Extracted from ResultView so each table owns its own filter state
  // (a spec can carry several tables). Column type comes straight from the cell
  // `type` — money/count → numeric, date → date range, text → contains.
  import type { ResultValue, EntityKind } from "$lib/protocol";

  let {
    headers,
    rows,
    entities,
  }: {
    headers: string[];
    rows: ResultValue[][];
    entities: (EntityKind | null)[];
  } = $props();

  type ColType = "money" | "count" | "date" | "text";

  // First non-null cell's type per column (columns are homogeneous in practice).
  const colTypes = $derived<ColType[]>(
    headers.map((_, ci) => {
      for (const r of rows) {
        const c = r[ci];
        if (c != null) return c.type as ColType;
      }
      return "text";
    }),
  );
  const isNum = (t: ColType) => t === "money" || t === "count";
  const hasNumeric = $derived(colTypes.some(isNum));
  // A sample money cell text (e.g. "$1,234.56") to match the footer's formatting.
  const moneySample = $derived(
    rows.flatMap((r) => r).find((c) => c?.type === "money")?.text ?? "$0.00",
  );

  // Which text columns deep-link. Entity columns (merchant/tag/month) already do;
  // a plain text column whose header reads like a transaction description links to
  // the Vault filtered by that description (?desc=).
  const DESC_HEADERS = /^(description|desc|payee|detail|details|transaction|memo|narrative|item|name)$/;
  function descLinkable(ci: number): boolean {
    return (
      colTypes[ci] === "text" &&
      !entities[ci] &&
      DESC_HEADERS.test((headers[ci] ?? "").trim().toLowerCase())
    );
  }

  // ── filter state, keyed by column index (lazy — avoids sizing to `headers`) ───
  let showFilters = $state(false);
  let textF = $state<Record<number, string>>({});
  let numMin = $state<Record<number, string>>({});
  let numMax = $state<Record<number, string>>({});
  let dateFrom = $state<Record<number, string>>({});
  let dateTo = $state<Record<number, string>>({});

  const hasVal = (r: Record<number, string>) => Object.values(r).some((v) => v?.trim());
  const anyActive = $derived(
    hasVal(textF) || hasVal(numMin) || hasVal(numMax) || hasVal(dateFrom) || hasVal(dateTo),
  );

  function clearFilters() {
    textF = {};
    numMin = {};
    numMax = {};
    dateFrom = {};
    dateTo = {};
  }

  function rowPasses(row: ResultValue[]): boolean {
    for (let ci = 0; ci < headers.length; ci++) {
      const c = row[ci];
      const t = colTypes[ci];
      if (isNum(t)) {
        const raw = c && (c.type === "money" || c.type === "count") ? c.raw : NaN;
        const lo = parseFloat(numMin[ci] ?? "");
        const hi = parseFloat(numMax[ci] ?? "");
        if (!Number.isNaN(lo) && (Number.isNaN(raw) || raw < lo)) return false;
        if (!Number.isNaN(hi) && (Number.isNaN(raw) || raw > hi)) return false;
      } else if (t === "date") {
        const v = c && c.type === "date" ? c.value : "";
        const d = Date.parse(v);
        const from = dateFrom[ci] ?? "";
        const to = dateTo[ci] ?? "";
        if (from && !Number.isNaN(d) && d < Date.parse(from)) return false;
        // include the whole "to" day: compare against end-of-day
        if (to && !Number.isNaN(d) && d > Date.parse(to) + 86_399_000) return false;
      } else {
        const q = (textF[ci] ?? "").trim().toLowerCase();
        if (q) {
          const s = (c && c.type === "text" ? c.value : c ? cellText(c) : "").toLowerCase();
          if (!s.includes(q)) return false;
        }
      }
    }
    return true;
  }

  const filteredRows = $derived(anyActive ? rows.filter(rowPasses) : rows);

  // Footer sum per numeric column over the *filtered* rows.
  const totals = $derived(
    headers.map((_, ci) => {
      if (!isNum(colTypes[ci])) return null;
      let s = 0;
      for (const r of filteredRows) {
        const c = r[ci];
        if (c && (c.type === "money" || c.type === "count")) s += c.raw;
      }
      return s;
    }),
  );

  function cellText(v: ResultValue): string {
    if (v == null) return "";
    if (v.type === "money" || v.type === "count") return v.text;
    return v.value;
  }
  function fmtTotal(n: number, ci: number): string {
    if (colTypes[ci] === "count") return n.toLocaleString("en-US");
    // Match the money cells' formatting: reuse their leading symbol.
    const sym = (moneySample.match(/^[^\d.,-]*/) ?? [""])[0];
    const sign = n < 0 ? "-" : "";
    const body = Math.abs(n).toLocaleString("en-US", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    return `${sign}${sym}${body}`;
  }
  function entityHref(kind: EntityKind, cell: ResultValue): string {
    return `/vault?${kind}=${encodeURIComponent(cellText(cell))}`;
  }
  function descHref(cell: ResultValue): string {
    return `/vault?desc=${encodeURIComponent(cellText(cell))}`;
  }
</script>

<div class="tbl-block">
  {#if rows.length > 3}
    <div class="tbl-toolbar">
      <button
        type="button"
        class="filt-toggle"
        class:on={showFilters || anyActive}
        onclick={() => (showFilters = !showFilters)}
        aria-pressed={showFilters}
        title="Filter these rows (date, description, amount)"
      >
        ⧩ Filter
      </button>
      {#if anyActive}
        <span class="filt-count">{filteredRows.length} of {rows.length}</span>
        <button type="button" class="filt-clear" onclick={clearFilters}>Clear</button>
      {/if}
    </div>
  {/if}

  <div class="tbl-wrap">
    <table class="tbl">
      <thead>
        <tr>{#each headers as h}<th>{h}</th>{/each}</tr>
        {#if showFilters}
          <tr class="filters">
            {#each headers as _, ci}
              <th>
                {#if isNum(colTypes[ci])}
                  <span class="rng">
                    <input class="fin num" type="number" inputmode="decimal" placeholder="min" bind:value={numMin[ci]} />
                    <input class="fin num" type="number" inputmode="decimal" placeholder="max" bind:value={numMax[ci]} />
                  </span>
                {:else if colTypes[ci] === "date"}
                  <span class="rng">
                    <input class="fin" type="date" bind:value={dateFrom[ci]} />
                    <input class="fin" type="date" bind:value={dateTo[ci]} />
                  </span>
                {:else}
                  <input class="fin" type="text" placeholder="contains…" bind:value={textF[ci]} />
                {/if}
              </th>
            {/each}
          </tr>
        {/if}
      </thead>
      <tbody>
        {#each filteredRows as row}
          <tr>
            {#each row as cell, ci}
              <td class:num={isNum(colTypes[ci])}>
                {#if entities[ci] && cell.type === "text"}
                  <a class="entity-link" href={entityHref(entities[ci]!, cell)} title="Show these records in the Vault">{cellText(cell)}</a>
                {:else if descLinkable(ci) && cellText(cell)}
                  <a class="entity-link" href={descHref(cell)} title="Show matching transactions in the Vault">{cellText(cell)}</a>
                {:else}{cellText(cell)}{/if}
              </td>
            {/each}
          </tr>
        {/each}
        {#if filteredRows.length === 0}
          <tr><td class="empty" colspan={headers.length}>No rows match the filters.</td></tr>
        {/if}
      </tbody>
      {#if hasNumeric && rows.length > 1}
        <tfoot>
          <tr>
            {#each headers as _, ci}
              <td class:num={isNum(colTypes[ci])}>
                {#if totals[ci] != null}{fmtTotal(totals[ci]!, ci)}{:else if ci === 0}Total{:else}{/if}
              </td>
            {/each}
          </tr>
        </tfoot>
      {/if}
    </table>
  </div>
</div>

<style>
  .tbl-block {
    max-width: 100%;
  }
  .tbl-toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 4px;
    font-size: 12px;
  }
  .filt-toggle,
  .filt-clear {
    padding: 2px 8px;
    border: 1px solid var(--border, rgba(127, 127, 127, 0.18));
    border-radius: 6px;
    background: var(--surface-2);
    color: var(--text-dim);
    cursor: pointer;
  }
  .filt-toggle.on {
    color: var(--accent, #7aa2f7);
    border-color: var(--accent, #7aa2f7);
  }
  .filt-toggle:hover,
  .filt-clear:hover {
    color: var(--text);
  }
  .filt-count {
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .tbl-wrap {
    overflow-x: auto;
    max-width: 100%;
    border-radius: var(--radius);
    border: 1px solid var(--border, rgba(127, 127, 127, 0.18));
  }
  .tbl {
    border-collapse: collapse;
    width: 100%;
    font-size: 13px;
  }
  .tbl th,
  .tbl td {
    padding: 6px 10px;
    text-align: left;
    border-bottom: 1px solid var(--border, rgba(127, 127, 127, 0.14));
    white-space: nowrap;
  }
  .tbl th {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--text-dim);
    font-weight: 600;
  }
  .tbl tr.filters th {
    padding: 4px 8px;
    text-transform: none;
    letter-spacing: 0;
  }
  .fin {
    width: 100%;
    min-width: 60px;
    padding: 2px 5px;
    font: inherit;
    font-size: 12px;
    color: var(--text);
    background: var(--bg);
    border: 1px solid var(--border, rgba(127, 127, 127, 0.3));
    border-radius: 4px;
  }
  .rng {
    display: flex;
    gap: 4px;
  }
  .rng .fin.num {
    min-width: 48px;
  }
  .tbl tbody tr:last-child td {
    border-bottom: none;
  }
  .tbl td.empty {
    text-align: center;
    color: var(--text-dim);
    padding: 12px;
  }
  .entity-link {
    color: inherit;
    text-decoration: underline dotted;
    text-underline-offset: 2px;
  }
  .entity-link:hover {
    color: var(--accent, #7aa2f7);
  }
  .tbl td.num {
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
  .tbl tfoot td {
    border-top: 2px solid var(--border, rgba(127, 127, 127, 0.28));
    border-bottom: none;
    font-weight: 600;
    color: var(--text);
    font-variant-numeric: tabular-nums;
  }
</style>
