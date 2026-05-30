# qmigrate — Differ layer design

Date: 2026-05-30
Status: Approved for implementation planning
Depends on: schema-spec.md v0.1 (the section 6 internal representation)

## 1. Purpose

The differ compares a **declared** schema (the section 6 internal representation produced by the DSL loader) against the **current** on-disk state of an HDB, and emits a classified set of differences. It only *detects and classifies*; the downstream plan and apply layers act on the result.

The public entry points read the HDB directly. Internally the work is split so that the actual file I/O (introspection) is separate from the comparison logic, which is pure and depends only on two section 6 representations.

## 2. Components

Four units in `src/diff.q`, namespace `.qm` (loaded after `src/qm.q`):

| Unit | I/O? | Signature | Responsibility |
|------|------|-----------|----------------|
| `.qm.i.introspect` | yes | `[hdbPath; table]` → section 6 rep, or `(::)` if absent | Read one on-disk table into a section 6 representation |
| `.qm.i.compare` | no (pure) | `[declared; actual; opts]` → diff rows | Compare two section 6 reps, classify each difference |
| `.qm.diffTable` | yes | `[hdbPath; declared; opts]` → result | Introspect + compare for a single declared table |
| `.qm.diff` | yes | `[hdbPath; declaredDict; opts]` → result | Map `diffTable` over a loadSchemas dict; add table-level add/unmanaged detection |

`compare` is the testable core. `introspect` is the only unit that touches the filesystem on the read path.

## 3. Introspection

Reads on-disk schema using `meta` on a memory-mapped directory (chosen over raw header reads and global `\l` for correctness without session-wide side effects).

- **Detect actual kind from layout.** If `hdbPath/<table>/.d` exists, the table is splayed. If the HDB root contains partition directories that each hold a `<table>/` directory, the table is partitioned. Absent in both → table does not exist on disk (`introspect` returns `(::)`).
- **Partition field** is inferred from the partition directory naming (date- or int-style). It is not stored as a column.
- **Read schema.** `t: get hsym <dir>` memory-maps the splayed directory (for partitioned tables, the **latest** partition's `<table>/` directory). `meta t` yields column names + order, type chars, attributes, and the foreign/enum domain (`f`).
- **Symbols / enumeration.** The root `sym` file is mapped first so enumerated symbol columns resolve to type `` `symbol `` rather than their raw enum domain.
- **In-memory tables** are never read from disk (see section 6).

### 3.1 Phase 1 assumption

Partition schemas are assumed uniform across partitions; only the latest partition is introspected. Detecting divergent per-partition schemas is out of scope for Phase 1.

## 4. Change catalog and severity

Each difference is one row classified with a severity. Severity rank: `ok < change < warning < destructive`.

| change | trigger | severity |
|--------|---------|----------|
| `newTable` | declared, absent on disk | change |
| `unmanagedTable` | on disk, not declared | warning |
| `addColumn` | column declared, not on disk | change |
| `attrChange` | attribute differs | change |
| `colOrderChange` | common columns differ in relative order | change |
| `dropColumn` | column on disk, not declared | destructive |
| `typeChange` | column type differs | destructive |
| `listChange` | list-ness (vector column) differs | destructive |
| `kindChange` | table kind differs (e.g. splayed vs partitioned) | destructive |
| `partitionChange` | partition field differs | destructive |
| `enumMismatch` | section 9: enumerated vs raw-symbol mismatch | warning |
| `skipped` | declared in-memory table (no disk target) | ok |

Notes:

- `kindChange` and `partitionChange` are classified `destructive` because the only Phase-1-conceivable remedy is drop-and-recreate; the apply layer that performs a recreate is itself Phase 2. The differ still reports them.
- `colOrderChange` is `change` (not destructive): for splayed/partitioned tables, reordering the same set of columns means rewriting the `.d` file only — no column data is moved. It fires only when the set of common columns appears in a different relative order on disk vs declared.
- A declared table absent on disk emits a single `newTable` row, not one `addColumn` row per column.
- `enumMismatch`: for partitioned tables a symbol column is enumerated by default (section 9); an on-disk symbol column with no enum domain (`f` empty) is a mismatch. Splayed/in-memory symbol columns are raw, so no enumeration is expected there.

## 5. Result representation

The core of a result is a flat detail table:

```q
rows: flip `table`column`change`from`to`severity`detail ! (
  // table:    symbol — table name
  // column:   symbol — column name, or ` for table-level rows
  // change:   symbol — from the section 4 catalog
  // from:     any    — current on-disk value (e.g. `int), or :: when not applicable
  // to:       any    — declared value, or :: when not applicable
  // severity: symbol — ok | change | warning | destructive
  // detail:   string — human-readable explanation
  ... )
```

The top-level result is a dict:

```q
`maxSeverity`applyable`rows ! (ms; ap; rows)
```

- `maxSeverity` (`ms`) — the highest severity present across all rows (`ok` if none).
- `applyable` (`ap`) — `0b` if any `destructive` row is present **and** `opts` does not set `allowDestructive`; otherwise `1b`. This is the single flag the plan layer reads to decide whether to proceed.
- `rows` — the detail table. For `.qm.diff`, rows span all tables; `ms`/`ap` are rolled up across the whole set.

## 6. Options

`opts` is a dict. Phase 1 recognises exactly one key:

| key | type | default | meaning |
|-----|------|---------|---------|
| `allowDestructive` | boolean | `0b` | When `1b`, destructive differences do not set `applyable` to false |

`()!()` selects defaults. Unknown option keys are rejected (consistent with the DSL's strict validation). `allowDestructive` affects only the `applyable` rollup; per-row severity is unchanged so the destructive rows remain visible.

## 7. Edge cases and error handling

- **Missing or non-directory `hdbPath`** → throw loudly before any comparison.
- **Declared in-memory table** → a single `skipped` row (severity `ok`); no disk read attempted.
- **Declared table absent on disk** → single `newTable` row.
- **On-disk table not in the declared set** (detected by `.qm.diff` only, which enumerates on-disk tables) → `unmanagedTable` warning; never auto-dropped.
- **Divergent partition schemas** → not detected in Phase 1 (latest-partition assumption, section 3.1).

## 8. Testing

No test framework is wired up yet, so the existing hand-rolled harness style is extended in a new `_smoke_diff.q`:

1. Build a tiny temporary HDB on disk: write one splayed table and one partitioned table (a couple of partitions) using ordinary q writes.
2. Run `.qm.diff` / `.qm.diffTable` against declared schemas that have been mutated to provoke each row in the section 4 catalog (add/drop/type/attr/list/order/kind/partition/enum/unmanaged/new/skipped).
3. Assert the produced rows, `maxSeverity`, and `applyable` — including the `allowDestructive` toggle flipping `applyable` for a destructive diff.
4. Same `chk`/`thr` assertion helpers; process exits non-zero on any failure.

The temporary HDB is created under a throwaway directory and removed at the end of the run.

## 9. Out of scope (Phase 1 differ)

- Applying any change (plan/apply layers are separate).
- Repartitioning, on-disk re-sorting, or kind conversion (only detected, classified destructive).
- Per-partition schema divergence detection.
- Foreign-key / cross-table differences.
- Reading Delta Control XML (the differ consumes the section 6 rep regardless of source).
