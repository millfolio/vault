// Pure formatting helpers shared by the Vault / Operations / status-bar UI. Kept
// framework-free and side-effect-free so they can be unit-tested headless (no DOM,
// no network) — the highest-value, lowest-flake coverage.

/** A location-bearing row (only `state`/`country` are read). */
export interface LocLike {
  state?: string;
  country?: string;
}
/** "State · Country" as compact text — blank when neither is set. */
export function fmtLoc(t: LocLike): string {
  const st = (t.state ?? "").trim();
  const co = (t.country ?? "").trim();
  if (st && co) return `${st} · ${co}`;
  return st || co;
}

/** A dated row: the raw `M/D` token plus a statement `year` (0 = unknown). */
export interface DateLike {
  date: string;
  year: number;
}
/** The date with its statement year appended when known (4/03 → 4/03/2026). */
export function fmtDate(t: DateLike): string {
  return t.year > 0 ? `${t.date}/${t.year}` : t.date;
}

/** A signed, formatted amount: debit = money OUT (−), credit = money IN (+). */
export function fmtMoney(amount: number, direction: string): string {
  const sign = direction === "debit" ? "-" : "+";
  const abs = Math.abs(amount).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  return `${sign}$${abs}`;
}

/** A magnitude as `$1,234.50` (always two decimals, absolute value). */
export function fmtDollars(n: number): string {
  return (
    "$" +
    Math.abs(n).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })
  );
}

/** Human byte size (`2.0 KB`, `1 MB`); sub-KiB stays in bytes. */
export function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const u = ["KB", "MB", "GB", "TB"];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(v < 10 ? 1 : 0)} ${u[i]}`;
}

// ── file-alias lookups (manifest files ↔ a row's alias) ───────────────────────
export interface FileLike {
  alias: string;
  name: string;
}
/** The indexed file behind an alias, or undefined when nothing matches. */
export function fileForAlias<F extends FileLike>(
  files: readonly F[] | undefined,
  alias: string,
): F | undefined {
  return files?.find((f) => f.alias === alias);
}
/** An alias → its real filename, falling back to the raw alias when unmatched. */
export function nameForAlias(
  files: readonly FileLike[] | undefined,
  alias: string,
): string {
  return fileForAlias(files, alias)?.name ?? alias;
}

// ── Operations panel ──────────────────────────────────────────────────────────
/** Pretty label for an operation type. */
export function opLabel(t: string): string {
  if (t === "index") return "Index";
  if (t === "reindex") return "Re-index";
  if (t === "backfill") return "Backfill";
  return t;
}
/** A duration (seconds between two epochs) as `3s` / `1m 04s`; guards clock skew. */
export function fmtDur(startedEpoch: number, finishedEpoch: number): string {
  const s = finishedEpoch - startedEpoch;
  if (!Number.isFinite(s) || s < 0) return "—";
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return `${m}m ${String(rem).padStart(2, "0")}s`;
}

// ── status bar ────────────────────────────────────────────────────────────────
/** A backfill ETA (seconds) as `5s` / `2 min`; always at least `1s`. */
export function fmtEta(s: number): string {
  return s >= 90 ? `${Math.round(s / 60)} min` : `${Math.max(1, Math.round(s))}s`;
}
/** The short, comparable form of a model id (drop the org prefix + `-int4`). */
export function shortId(id: string): string {
  return id
    .slice(id.lastIndexOf("/") + 1)
    .toLowerCase()
    .replace(/-int4$/, "");
}
