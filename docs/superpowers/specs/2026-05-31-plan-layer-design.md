# qmigrate — Plan layer design

Date: 2026-05-31
Status: Approved for implementation planning
Depends on: differ-design.md (the result dict it consumes) and schema-spec.md v0.1 (the section 6 internal representation)

## 1. Purpose

The plan layer consumes a **differ result** plus the **declared schemas** and produces an ordered, executable **migration plan**: the concrete operations that would bring the HDB into line with the declared schema. The division of labour across the three layers is:

- the **differ** detects and classifies differences (`.qm.diff`);
- the **plan layer** sequences those classified differences into ordered operations (`.qm.plan`);
- the **apply layer** (Phase 2) executes them.

The plan layer is **pure** — it performs no file I/O. It operates only on a differ result and the section 6 representations of the declared tables.

## 2. Entry point and signature

One public unit in `src/plan.q`, namespace `.qm` (loaded after `src/diff.q`):

```q
.qm.plan[differResult; declaredDict]   / -> plan result dict
```

| Argument | Meaning |
|----------|---------|
| `differResult` | The output of `.qm.diff` — a dict ``` `maxSeverity`applyable`rows ``` |
| `declaredDict` | The `loadSchemas` dict (`dict[tableName -> schemaDict]`) |

`declaredDict` is required: an `addColumn` or `createTable` operation needs the declared column's `type`, `list`, `attr`, `default`, and `defaultFn`, which live in the section 6 representation and are **not** carried in the differ rows (rows hold only the type symbol in `from`/`to`).

There is no `opts` argument. The destructive gate (`allowDestructive`) was already applied by the differ when it computed `applyable`; the plan layer propagates `differResult` `applyable` and `maxSeverity` rather than re-deriving them. This keeps a single source of truth for the gate.

`.qm.plan` is pure over its two inputs, mirroring the differ's pure `compare` core, and is fully testable without a disk.

## 3. Operation catalog

Each differ change maps to a plan operation (or to no operation). Severity is carried verbatim from the differ row.

| differ change | plan op | params | severity |
|---------------|---------|--------|----------|
| `newTable` | `createTable` | full column spec, kind, partitionField (from declared schema) | change |
| `addColumn` | `addColumn` | type, list, attr, and `default` *or* `defaultFn` | change |
| `attrChange` | `setAttr` / `clearAttr` | declared attr; `clearAttr` when the declared attr is `` ` `` | change |
| `colOrderChange` | `reorderColumns` | declared column order (the target `.d`) | change |
| `dropColumn` | `dropColumn` | — | destructive |
| `enumMismatch` | `reEnumerate` | direction (enumerate vs raw) | warning |
| `typeChange` | `manual` | note: requires drop-and-recreate (Phase 2) | destructive |
| `listChange` | `manual` | note | destructive |
| `kindChange` | `manual` | note | destructive |
| `partitionChange` | `manual` | note | destructive |
| `unmanagedTable` | — (no op) | — | — |
| `skipped` | — (no op) | — | — |

Notes:

- **`manual`** operations carry no executable params. They are visible flags telling the operator that a drop-and-recreate is required, which is Phase 2 work. The differ already classifies these four changes `destructive`; the plan surfaces them so a destructive plan reads as a complete picture, but it does not attempt to execute them.
- **`unmanagedTable`** and **`skipped`** produce no operation. The differ already surfaced them (an unmanaged table is a warning, never auto-dropped; a skipped in-memory table has no disk target). The plan layer is about actions, so it omits them.
- **`createTable`** emits a single operation built from the declared column spec — never one `addColumn` per column. This matches the differ, which emits a single `newTable` row for an absent table.
- **`attrChange` direction** is read from the row: when `to` (the declared value) is `` ` `` the op is `clearAttr`; otherwise `setAttr`.

## 4. Ordering

Operations are grouped by table in `declaredDict` order. Within a single table the operation order is deterministic:

1. `createTable` (for `newTable`; a created table has no other ops, since the differ emits only the single `newTable` row)
2. `addColumn` (all)
3. `dropColumn` (all)
4. `setAttr` / `clearAttr`
5. `reEnumerate`
6. `reorderColumns` (last)
7. `manual` (recreate-class) — appended at the table's end, informational only

The `seq` field (1..n) is assigned across the whole plan after ordering.

Rationale: add and drop operations mutate the set of columns, so the `.d` reorder must run after the column set has settled; attribute operations apply to columns that exist; `manual` entries do not execute, so their position is informational and they are grouped at the end of their table.

## 5. Result representation

```q
`maxSeverity`applyable`ops ! (ms; ap; opsTable)
```

- `maxSeverity` (`ms`) and `applyable` (`ap`) are propagated from `differResult`.
- `ops` is a flat table, built with `flip` (consistent with the differ's row table, and required because `params` is a dict-valued column), one row per operation, with these columns:

```q
// seq:      long   — execution order, 1..n
// table:    symbol — table name
// column:   symbol — column name, or ` for table-level ops
//                    (createTable, reorderColumns, kind/partition manual)
// op:        symbol — from the section 3 catalog
// change:   symbol — originating differ change (traceability)
// severity: symbol — carried from the differ row
// detail:   string — human-readable per-line explanation
// params:   dict   — op-specific payload; ()!() when none
```

An empty diff (no differences) yields a 0-row `ops` table, `applyable` `1b`, and `maxSeverity` `` `ok ``.

## 6. Components

Three units in `src/plan.q`, namespace `.qm`, loaded after `diff.q`. The private/public split mirrors `diff.q`.

| Unit | I/O? | Signature | Responsibility |
|------|------|-----------|----------------|
| `.qm.i.opFor` | no (pure) | `[declared; row]` → 0+ op rows | Map one differ row to plan op row(s) |
| `.qm.i.orderOps` | no (pure) | `[opsTable]` → opsTable | Stable-sort into execution order, assign `seq` |
| `.qm.plan` | no (pure) | `[differResult; declaredDict]` → result | Map `opFor` over the rows, order, roll up |

All three are pure, so the whole layer is unit-testable without a disk.

## 7. Edge cases and error handling

- **`newTable`** → one `createTable` op built from the declared column spec; no per-column `addColumn`.
- **`defaultFn`** → carried as a symbol in the `addColumn` params; the plan does **not** resolve it. Resolution happens at apply time (schema-spec §5.2). The `detail` notes "computed default via `<fn>`".
- **`attrChange` direction** → derived from the row's `to` value (see section 3).
- **Malformed input** → throw loudly. `differResult` must carry the expected keys; `declaredDict` must be keyed by table name. This is consistent with the DSL's and differ's loud-error stance.
- **Declared table with no diff rows** → contributes no operations.

## 8. Testing

No test framework is wired up yet, so the existing hand-rolled harness style is extended in a new `_smoke_plan.q`, with two paths:

1. **Pure path.** Hand-built differ-result dicts plus declared schemas, provoking each operation in the section 3 catalog. Assert the operation type, `seq` ordering, `params`, `severity`, `detail`, `applyable` propagation, `manual` flagging of the recreate-class changes, and the empty-plan case.
2. **End-to-end path.** Reuse the `_smoke_diff` temporary-HDB fixture: `.qm.diff` against mutated declared schemas, then `.qm.plan` on the result, asserting the produced operations.

Same `chk`/`thr` assertion helpers; the process exits non-zero on any failure.

## 9. Out of scope (Phase 1 plan)

- Executing any operation (the apply layer is separate, Phase 2).
- Drop-and-recreate for `typeChange` / `listChange` / `kindChange` / `partitionChange` (flagged `manual` only).
- Per-partition operation expansion (the apply layer fans a logical op out across partition directories).
- Cross-table or foreign-key ordering (no foreign keys in Phase 1).
- Resolving `defaultFn` references (apply-time concern).
- Report formatting (the report layer is separate).
