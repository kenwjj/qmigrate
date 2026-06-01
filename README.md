# qmigrate

Schema migration tooling for kdb+/q. Declare table schemas as data, diff them against a live HDB, and apply the changes safely.

> **Status:** Phase 1, in development. The native q schema DSL, the differ, the plan layer, and the apply layer are implemented and verified; the report layer is not yet built.

## What it does

qmigrate separates *declaring* a schema from *mutating* on-disk data:

1. **Declare** — write one `.q` file per table describing its shape, columns, types, attributes, and defaults. Schema files are pure data (no side effects).
2. **Load** — `.qm.loadSchemas` reads a directory of schema files into a single normalised internal representation.
3. **Diff** — `.qm.diff` compares the declared schema against an existing HDB and classifies every difference by severity. **plan / apply** — produce a migration plan and apply it to the HDB.

Two input formats produce the same internal representation: the **native q DSL** (this phase) and **Delta Control XML** (separate spec, later phase).

## The schema DSL

Six functions, four modifier keys. Each schema file is a single expression returning a schema dict.

```q
// schemas/trade.q — a partitioned table
.qm.schema[`trade] (
  .qm.partitioned[`date];

  .qm.col [`time;     `timestamp];
  .qm.colx[`sym;      `symbol;    `attr`p];
  .qm.col [`price;    `float];
  .qm.col [`size;     `long];
  .qm.colx[`exchange; `symbol;    `default`attr!(`NYSE;`g)]
  )
```

| Function | Purpose |
|----------|---------|
| `.qm.partitioned[partField]` / `.qm.splayed[]` / `.qm.memory[]` | table-shape helper (exactly one per schema) |
| `.qm.col[name; type]` | plain column |
| `.qm.colx[name; type; modifiers]` | column with modifiers (`attr`, `default`, `defaultFn`, `list`) |
| `.qm.schema[name; parts]` | construct + validate a schema dict |
| `.qm.loadSchemas[dir]` | recursively load a directory of schema files |

Full reference: **[schema-spec.md](schema-spec.md)**. Worked examples: **[schemas/](schemas/)**.

## Differ

`src/diff.q` compares a declared schema against an on-disk HDB and classifies
each difference (severity rank `ok < change < warning < destructive`):

```q
\l src/qm.q
\l src/diff.q
schemas: .qm.loadSchemas `:schemas;
result:  .qm.diff[`:/path/to/hdb; schemas; ()!()];
result`maxSeverity   / `ok | `change | `warning | `destructive
result`applyable     / 0b if destructive changes present and not opted in
result`rows          / table of classified differences

/ allow destructive changes through the applyable gate:
.qm.diff[`:/path/to/hdb; schemas; (enlist`allowDestructive)!enlist 1b];
```

`.qm.diffTable[hdbPath; declared; opts]` diffs a single declared table. The
differ only detects and classifies — the plan / apply layers (later) act on the
result. Design: **[docs/superpowers/specs/2026-05-30-differ-design.md](docs/superpowers/specs/2026-05-30-differ-design.md)**.

### Determining the diff between a schema and an HDB

Step by step, from a q session (set `QLIC` first — see [Running](#running)):

1. **Load the differ.** It depends on the DSL, so load `src/qm.q` before `src/diff.q`:

   ```q
   \l src/qm.q
   \l src/diff.q
   ```

2. **Load the declared schemas.** Point `.qm.loadSchemas` at a directory of schema
   files; it recurses and returns one dict keyed by table name:

   ```q
   schemas: .qm.loadSchemas `:schemas;
   ```

3. **Run the diff against the HDB root.** Pass the HDB path as a file symbol, the
   schema dict, and an options dict (`()!()` for defaults):

   ```q
   result: .qm.diff[`:/path/to/hdb; schemas; ()!()];
   ```

4. **Read the rollup.** Two scalars summarise the whole result:

   ```q
   result`maxSeverity   / highest severity present: `ok | `change | `warning | `destructive
   result`applyable     / 0b if any destructive change is present and not opted in, else 1b
   ```

5. **Inspect the detail rows.** `result`rows` is a table — one row per difference —
   with columns `table` `column` `change` `from` `to` `severity` `detail`.
   Filter it with qsql to see what changed:

   ```q
   result`rows                                          / everything
   select from result`rows where severity=`destructive  / only the blocking changes
   select table, column, change, detail from result`rows where table=`trade
   ```

   `from` is the current on-disk value, `to` is the declared value (`::` where not
   applicable). Change kinds and their severities are catalogued in the
   [design doc §4](docs/superpowers/specs/2026-05-30-differ-design.md).

6. **Opt in to destructive changes (optional).** Destructive diffs (drop column,
   type change, kind/partition change) set `applyable` to `0b` by default. To let
   them through the gate — they still appear in `rows` — set `allowDestructive`:

   ```q
   result: .qm.diff[`:/path/to/hdb; schemas; (enlist`allowDestructive)!enlist 1b];
   ```

To diff a single declared table instead of a whole directory, use
`.qm.diffTable[hdbPath; declared; opts]` with one schema dict
(e.g. ``.qm.loadSchemas[`:schemas]`trade``) in place of the dict.

## Plan

`src/plan.q` turns a differ result plus the declared schemas into an ordered,
pure migration plan. It performs no disk I/O — the differ already read the HDB.

```q
\l src/qm.q
\l src/diff.q
\l src/plan.q
schemas: .qm.loadSchemas `:schemas;
diffResult: .qm.diff[`:/path/to/hdb; schemas; ()!()];
plan: .qm.plan[diffResult; schemas];
plan`maxSeverity    / carried from the differ result
plan`applyable      / carried from the differ result (the apply layer gates on this)
plan`ops            / ordered table of operations: seq table column op change severity detail params
```

Each row of ``plan`ops`` is one operation, ordered for execution (`seq` 1..n).
Recreate-class changes (`typeChange`/`listChange`/`kindChange`/`partitionChange`)
appear as `manual` operations — visible flags that a drop-and-recreate is needed
(Phase 2), not executable steps. The plan layer only sequences — the apply layer
(later) executes. Design:
**[docs/superpowers/specs/2026-05-31-plan-layer-design.md](docs/superpowers/specs/2026-05-31-plan-layer-design.md)**.

## Apply

`src/apply.q` executes a plan result against the on-disk HDB. It is the only
layer that writes. A read-only preflight validates the work and resolves any
`defaultFn` references; then it backs up every file it will touch, runs the
operations in `seq` order (fanning out across partitions), and rolls back from
the backup if any operation fails.

```q
\l src/qm.q
\l src/diff.q
\l src/plan.q
\l src/apply.q
schemas: .qm.loadSchemas `:schemas;
diffResult: .qm.diff[`:/path/to/hdb; schemas; ()!()];
plan:       .qm.plan[diffResult; schemas];
result:     .qm.apply[`:/path/to/hdb; plan; ()!()];
result`status   / `applied | `rolledBack | `dryRun | `blocked | `noop
result`ops      / report table: seq table column op severity status detail
result`backup   / backup dir path (left in place on success), or ` when none

/ preview without writing:
.qm.apply[`:/path/to/hdb; plan; (enlist`dryRun)!enlist 1b];
```

Apply refuses to mutate when `plan`applyable` is `0b` (status `blocked`); opt in
to destructive changes by re-running `diff`/`plan` with `allowDestructive`.
Recreate-class `manual` ops are reported `skipped`, never executed. Design:
**[docs/superpowers/specs/2026-05-31-apply-layer-design.md](docs/superpowers/specs/2026-05-31-apply-layer-design.md)**.

## Layout

```
src/qm.q          the .qm DSL implementation
src/diff.q        the differ (.qm.diff / .qm.diffTable); loaded after qm.q
src/plan.q        the plan layer (.qm.plan); loaded after diff.q
src/apply.q       the apply layer (.qm.apply); loaded after plan.q
schemas/          example schema files (one table per file; loader recurses)
schema-spec.md    canonical DSL specification (v0.1)
test/run.q        qcumber runner: q test/run.q -q (exits non-zero on any failure)
test/helpers.q    shared test helpers (thr, rmrf, mkcols, mkrep)
test/*.quke       qcumber tests, one per src layer (qm, diff, plan, apply)
test/_smoke*.q    original hand-rolled harnesses, kept as a dependency-free fallback
lib/ax/           vendored minimal qcumber (KX AX libraries; proprietary -- see lib/ax/NOTICE)
```

## Running

Requires kdb+/q. Developed against **KDB-X 5.0**.

Load the DSL into a q session:

```q
\l src/qm.q
schemas: .qm.loadSchemas `:schemas;
```

Run the smoke check (exits non-zero on any failure):

```
q test/_smoke.q -q
```

> On Windows with the free KDB-X edition, the license lives at `C:\q\kc.lic`; set `QLIC=C:\q` so q can find it. Full invocation used here:
> `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe test/_smoke.q -q`

## Testing

The test suite uses **qcumber** (`.quke` BDD files). Run it from the repo root:

    q test/run.q -q

The runner loads the vendored qcumber under `lib/ax/`, loads `src/*` and
`test/helpers.q`, runs every `*.quke` in `test/`, and exits non-zero on any
failed expectation or parse error (printing `qcumber: TOTAL=.. FAIL=.. PARSEERR=..`).
`test/{qm,diff,plan,apply}.quke` cover the DSL, differ, plan, and apply layers
respectively, porting every assertion from the original `_smoke*.q` harnesses.

> qcumber is the KX Developer AX library suite. It does not officially support
> KDB-X 5.0 (the IDE rejects v5), but the standalone runner has no version gate;
> a minimal subset is vendored under `lib/ax/` with the Windows native libs
> relocated to `ws/lib/` so the AX loader resolves them. Windows-only. See
> `lib/ax/NOTICE` (proprietary; private repo only).

The `test/_smoke*.q` files remain as a dependency-free fallback (e.g.
`q test/_smoke.q -q`, run from the repo root), each exiting non-zero on failure.

## Phase 1 scope

In scope: splayed / partitioned / in-memory tables; scalar and vector columns; all native q types; column attributes (`p`/`s`/`u`/`g`) declared and validated; literal and computed defaults; root-sym-file enumeration for partitioned tables.

Out of scope (Phase 1): foreign keys, nested/compound column types, multi-sym-file enums, per-table compression, on-disk re-sorting, mixed schema sources, writing Delta Control XML. See [schema-spec.md §11](schema-spec.md).
