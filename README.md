# qmigrate

Schema migration tooling for kdb+/q. Declare table schemas as data, diff them against a live HDB, and apply the changes safely.

> **Status:** Phase 1, in development. The native q schema DSL and the differ are implemented and verified; the plan / apply / report layers are not yet built.

## What it does

qmigrate separates *declaring* a schema from *mutating* on-disk data:

1. **Declare** — write one `.q` file per table describing its shape, columns, types, attributes, and defaults. Schema files are pure data (no side effects).
2. **Load** — `.qm.loadSchemas` reads a directory of schema files into a single normalised internal representation.
3. **Diff** — `.qm.diff` compares the declared schema against an existing HDB and classifies every difference by severity. *(future)* **plan / apply** — produce a migration plan and apply it.

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

## Layout

```
src/qm.q          the .qm DSL implementation
src/diff.q        the differ (.qm.diff / .qm.diffTable); loaded after qm.q
schemas/          example schema files (one table per file; loader recurses)
schema-spec.md    canonical DSL specification (v0.1)
_smoke.q          manual verification check for the DSL
_smoke_diff.q     manual verification check for the differ (builds a temp HDB)
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
q _smoke.q -q
```

> On Windows with the free KDB-X edition, the license lives at `C:\q\kc.lic`; set `QLIC=C:\q` so q can find it. Full invocation used here:
> `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke.q -q`

## Testing

No test framework is wired up yet — the `_smoke*.q` files are temporary hand-rolled harnesses (each exits non-zero on any failure). `_smoke.q` covers the DSL (every spec §8 example and §7 validation rule); `_smoke_diff.q` covers the differ — it builds a throwaway HDB under `testhdb/`, exercises every change in the catalog, and removes the fixture on exit. Run with `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`. A proper framework is still to be chosen.

## Phase 1 scope

In scope: splayed / partitioned / in-memory tables; scalar and vector columns; all native q types; column attributes (`p`/`s`/`u`/`g`) declared and validated; literal and computed defaults; root-sym-file enumeration for partitioned tables.

Out of scope (Phase 1): foreign keys, nested/compound column types, multi-sym-file enums, per-table compression, on-disk re-sorting, mixed schema sources, writing Delta Control XML. See [schema-spec.md §11](schema-spec.md).
