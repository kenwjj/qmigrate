# qmigrate — Apply layer design

Date: 2026-05-31
Status: Approved for implementation planning
Depends on: plan-layer-design.md (the plan result it consumes), differ-design.md (the section 6 / result reuse), and schema-spec.md v0.1 (column materialisation semantics, sections 5.2 and 9)

## 1. Purpose

The apply layer consumes a **plan result** (`.qm.plan` output) and **executes** its operations against the on-disk HDB, bringing the HDB into line with the declared schema. It is the final layer in the division of labour:

- the **differ** detects and classifies differences (`.qm.diff`);
- the **plan layer** sequences those classified differences into ordered operations (`.qm.plan`);
- the **apply layer** executes them (`.qm.apply`).

Apply is the **only** layer that mutates the filesystem. Where the differ and plan layers kept a pure core, apply is inherently I/O. Its design isolates a read-only **preflight** core (fully testable without mutation) from the write-path handlers, and wraps the whole run in a **backup-then-mutate with rollback** safety model.

## 2. Entry point and signature

One public unit in `src/apply.q`, namespace `.qm` (loaded after `src/plan.q`):

```q
.qm.apply[hdbPath; planResult; opts]   / -> apply result dict
```

| Argument | Meaning |
|----------|---------|
| `hdbPath` | HDB root, a file symbol (e.g. `` `:/data/hdb ``). Present because apply **writes** (the plan layer was pure and took no path). |
| `planResult` | The output of `.qm.plan` — a dict ``` `maxSeverity`applyable`ops ``` |
| `opts` | A dict; recognised keys in section 2.1. Unknown keys are rejected (consistent with `diff`'s `normOpts`). |

`declaredDict` is **not** an argument: the plan layer already baked the declared column information an executable op needs (`type`, `list`, `attr`, `default`/`defaultFn`, column order, kind, partitionField) into each op's `params`. Apply reads only `hdbPath`, the ops, and the ambient q session (for resolving `defaultFn` symbols via `get`).

There is no `allowDestructive` option here. The destructive gate is a single source of truth: it was applied by the differ when it computed `applyable`, and propagated by the plan layer. Apply **refuses to mutate** when `planResult` `applyable` is `0b`. To allow destructive changes through, the operator re-runs `diff`/`plan` with `allowDestructive` set.

### 2.1 Options

| key | type | default | meaning |
|-----|------|---------|---------|
| `dryRun` | boolean | `0b` | When `1b`: run preflight (so bad `defaultFn`/attr still fail loud) and report the planned physical actions, but take no backup and perform no writes. |
| `backupDir` | symbol | `` ` `` | Sidecar backup location. `` ` `` selects the default `` `:<hdbPath>/.qmbackup ``. |

`()!()` selects defaults.

## 3. Result representation

```q
`status`ops`backup ! (st; reportTable; backupPath)
```

- **`status`** — one of:
  - `` `applied `` — all executable ops succeeded; backup left in place for the operator to inspect/delete.
  - `` `rolledBack `` — an op failed mid-run; the HDB was restored from backup.
  - `` `dryRun `` — preflight passed; nothing written.
  - `` `blocked `` — `planResult` `applyable` was `0b`; no preflight work, no backup.
  - `` `noop `` — zero executable ops (empty plan, or all `manual`).
- **`ops`** — the report table, built with `flip` (one row per plan op), columns:

```q
// seq:      long   — execution order (carried from the plan)
// table:    symbol — table name
// column:   symbol — column name, or ` for table-level ops
// op:       symbol — the plan op
// severity: symbol — carried from the plan op
// status:   symbol — done | skipped | failed | rolledBack | planned
// detail:   string — human-readable per-line outcome
```

`status` per op: `done` (executed), `skipped` (a `manual` op — never executed), `failed` (the op that threw), `rolledBack` (ops reverted by restore, including those already done before the failure), `planned` (dryRun — would execute).

- **`backup`** — the backup directory path, or `` ` `` when none was taken (`dryRun`/`blocked`/`noop`).

## 4. Components

Units in `src/apply.q`, namespace `.qm`, loaded after `plan.q`. The private/public split mirrors `diff.q`/`plan.q`.

| Unit | I/O? | Signature | Responsibility |
|------|------|-----------|----------------|
| `.qm.i.partDirs` | read | `[root; table; kind]` → dir list | The physical directories an op fans out to. Splayed → `` enlist `:root/table ``. Partitioned → `` `:root/<part>/table `` for **every** partition (apply must hit all; the differ only read the latest for schema introspection). |
| `.qm.i.preflight` | read | `[root; ops; opts]` → worklist | **Phase 1.** Gate `applyable`; for each executable op: resolve `defaultFn` via `get` (fail loud if missing), validate attr-satisfiability against on-disk data, gather fan-out dirs and row counts, record sentinel-partition pre-existence (section 6.1), accumulate the backup set. Performs **no writes**; throws on any problem. |
| `.qm.i.backup` / `.qm.i.restore` | write | `[root; backupDir; set]` | Copy the backup set to the sidecar; restore it (and delete created files/dirs) on rollback. |
| `.qm.i.do<Op>` | write | `[root; op; ctx]` → `()` | One handler per executable op (section 5). `ctx` carries the preflight-resolved values (fan-out dirs, row counts, resolved default vectors, sentinel info). |
| `.qm.i.execute` | write | `[root; worklist; opts]` → report | **Phases 2–3.** `backup` once, iterate ops in `seq` order, dispatch to handlers; on any throw, `restore` and mark the report. |
| `.qm.apply` | write | `[root; planResult; opts]` → result | `normOpts` → `preflight` → (`dryRun` ? report planned : `execute`) → roll up `status`. |

Handler dispatch table:

```q
i.handler: `createTable`addColumn`dropColumn`setAttr`clearAttr`reorderColumns`reEnumerate ! (...)
```

The testable seam: `preflight` gathers *what to do* (data, no mutation) and the handlers *do it* (I/O). Preflight is exercisable against a temp HDB without changing a byte.

## 5. Operation handlers

Each handler fans out across `i.partDirs` (splayed = one directory, partitioned = N partition directories). `ctx` holds the values preflight resolved.

### 5.1 `createTable` (change)

Declared table absent on disk.

- **splayed**: write each declared column as a 0-count typed vector to `` `:root/table/<col> ``, then write `.d` in declared order. Splayed symbol columns are raw (no enumeration, schema-spec section 9).
- **partitioned** (sample-then-truncate): a partitioned table with no rows has no partition directories to write, so apply forces it into existence and then empties it:
  1. Build a **1-row sample** in-memory table from the schema — one typed-null value per stored column (list columns get an `enlist` of an empty typed list).
  2. Write the sample through the **standard partitioned-write path** — enumerate symbol columns against the root `sym`, apply the declared attributes, write column files and `.d` — into a single **sentinel partition** (section 6.1). Leaning on the real writer guarantees on-disk format parity (enum domain, `` `p# `` etc.); it avoids hand-rolled 0-count files that could subtly mis-format.
  3. **Truncate**: rewrite each column file in that partition as `0#`, leaving a correctly-formatted, **present, empty** partitioned table. A subsequent `diff` no longer reports `newTable`.

The partition column is virtual (derived from the directory name, not stored), so step 1 needs a sentinel partition value (section 6.1). Report `detail`: `"created empty partitioned table at sentinel partition <pv>"`.

### 5.2 `addColumn` (change)

For each fan-out directory:

- row count `n` = count of an existing on-disk column (read via `.d`).
- build the fill vector of length `n`:
  - `defaultFn` set → `ctx` holds `get[fn][dir; col]` (schema-spec section 5.2 signature `{[path; columnName]}`); assert the result is length `n` and of the column's type.
  - `default` set → broadcast the scalar (`n # default`); a list column places the value in each cell (`n # enlist default`, schema-spec section 5.2).
  - neither → `n #` typed null for a scalar column, `n # enlist` empty-typed list for a list column.
- partitioned **and** symbol type → enumerate the fill against the root `sym` (extending the `sym` file, schema-spec section 9) and write the enum vector; otherwise write raw.
- write `` `:dir/col `` and append `col` to `.d`.

### 5.3 `dropColumn` (destructive)

For each directory: `hdel` the column file `` `:dir/col `` and remove `col` from `.d`. The destroyed data is in the backup set.

### 5.4 `setAttr` (change)

For each directory: preflight has already validated the data satisfies the attribute (`s` = sorted, `u` = unique, `p` = parted — apply **never** sorts data, schema-spec section 5.2). The handler reads the column, applies the marker (`` `p# `` / `` `s# `` / `` `u# `` / `` `g# ``), and writes it back.

### 5.5 `clearAttr` (change)

For each directory: read the column, strip the attribute (`` `# ``), write it back.

### 5.6 `reorderColumns` (change)

For each directory: rewrite `.d` to `params` `order` (the full declared column set). Column data files are untouched.

### 5.7 `reEnumerate` (warning)

`params` `enumerate` gives the direction. `1b` (partitioned, should be enumerated but raw on disk) → enumerate the column against the root `sym` and write the enum vector. The reverse direction is symmetric, but the Phase-1 differ only emits the enumerate-needed case.

### 5.8 `manual`

Never reaches a handler. `execute` marks it `skipped` in the report (recreate-class change, non-executable in Phase 1 per the plan-layer design).

### 5.9 Borrowed idioms

The `.d` read/rewrite pattern, the `` @[dir; col; `p#] ``-style attribute application, and enumerate-via-root-`sym` follow kx `dbmaint.q` techniques but are **reimplemented** in our own code, wrapped in our backup model. `dbmaint.q` is not taken as a dependency (it mutates in place with no rollback hook).

## 6. Backup, rollback, and the sentinel partition

### 6.1 Sentinel partition (partitioned `createTable`)

A fixed far-past sentinel keyed by partition-field type:

| partitionField type | sentinel directory |
|---------------------|--------------------|
| date | `1900.01.01` |
| month | `1900.01` |
| int / year | `0` |

It is clearly fake, sorts before real data, and the operator drops it once real data lands. A fixed sentinel in Phase 1; an `opts` override can be added later if a real HDB ever needs it.

### 6.2 Backup set granularity (computed in preflight)

- Files we **overwrite or destroy** (dropColumn data, setAttr/clearAttr/reEnumerate columns, every `.d` rewritten) → **copied** to the sidecar.
- Files we **create** (addColumn column files) → recorded on a **create-list**; rollback deletes them (no copy needed).
- Any op that extends the root `sym` (addColumn / reEnumerate of symbol columns) → `sym` is added to the backup set (a global mutation outside the table directories).
- The sentinel `createTable` create-list has **directory** granularity: the table subdir `` `:root/<sentinel>/<table> `` is always ours; if the sentinel partition directory itself was **absent before** the run, it is also on the delete-list. Preflight records this pre-existence.

### 6.3 Rollback

- A handler throwing mid-run triggers `restore`: copy backed-up files back, delete created files and created directories **deepest-first**, mark the failing op `failed` and all not-yet-run ops `rolledBack` (ops already completed are reverted by the restore too). Result `status` is `rolledBack`.
- A freshly-created sentinel partition is removed entirely on rollback — no half-built artifact left behind. A pre-existing sentinel partition (a real HDB with 1900 data) keeps its other tables; only our table subdir is removed.
- On a **clean** run the backup directory is left in place for the operator to inspect and delete; `status` is `applied`. Cleanup of the sentinel partition happens only on rollback/failure — on success the intended empty table is exactly what remains.
- A failure of `restore` itself is loud: throw, leave the backup directory intact, and the report records `rolledBack` as incomplete with the backup path for manual recovery.

## 7. Edge cases and error handling

**Fail-before-touching-data (preflight throws, nothing mutated):**

- `applyable` is `0b` → no preflight work; return `status` `blocked`, no backup.
- A `defaultFn` symbol does not resolve via `get` → throw (schema-spec section 5.2 requires this fail before any data is touched).
- An attribute is declared but the on-disk data does not satisfy it (not sorted / unique / parted) → throw. Apply never sorts data as a side effect (schema-spec section 5.2).
- Malformed `planResult` (missing `ops` / `applyable`) → throw, matching the loud-error stance of the DSL, differ, and plan layers.

**Other:**

- `manual` ops → `skipped` in the report, never executed.
- Empty or all-`manual` ops → `status` `noop`, no backup.
- `dryRun` → preflight runs (still fails loud on bad `defaultFn`/attr), the report lists `planned` actions including the fan-out directory count, no backup, no writes.
- **Offline assumption** — apply runs against an HDB that is not being served or memory-mapped by another process. Concurrent-access safety is out of Phase-1 scope.

## 8. Testing

No test framework is wired up yet, so the existing hand-rolled harness style is extended in a new `_smoke_apply.q` (same `chk`/`thr` helpers; the process exits non-zero on any failure). It builds a throwaway HDB under `testhdb_apply/` and removes it on exit.

1. **End-to-end happy path.** Temp HDB → mutate declared schemas → `diff` → `plan` → `apply`. Assert each op mutated disk correctly by **re-diffing**: the post-apply `diff` returns `maxSeverity` `` `ok ``. Cover every executable op: `createTable` (splayed and partitioned-via-sentinel), `addColumn` (literal default, `defaultFn`, and list column), `dropColumn`, `setAttr`/`clearAttr`, `reorderColumns`, `reEnumerate`.
2. **Preflight fail-loud (nothing mutated).** A missing `defaultFn` symbol and attribute-unsatisfiable data each throw; assert the on-disk bytes are unchanged.
3. **Rollback.** Inject a mid-execute failure (a handler that throws on op N). Assert the HDB is restored to its original state (re-diff matches the pre-apply diff), a freshly-created sentinel partition is removed, and the report marks `failed`/`rolledBack`.
4. **dryRun.** Assert zero disk change, no backup directory, and a report whose ops are all `planned`.
5. **Idempotency.** Apply twice; the second run is `noop` (the re-diff is already `ok`).
6. **Gate.** A plan with `applyable` `0b` yields `status` `blocked` and performs no writes.

## 9. Out of scope (Phase 1 apply)

- Executing `manual` (recreate-class) ops — `typeChange` / `listChange` / `kindChange` / `partitionChange` are reported `skipped`, never drop-and-recreated.
- Concurrent-access safety against a live/served HDB (offline assumption, section 7).
- Per-partition schema divergence (the differ assumes uniform partitions; apply fans out the same logical op to every partition).
- Multi-sym-file enumeration domains (root `sym` only, schema-spec section 9).
- On-disk re-sorting of data to satisfy an attribute (apply validates, never sorts — schema-spec section 5.2).
- An `opts`-overridable sentinel partition value (fixed in Phase 1, section 6.1).
- Foreign-key / cross-table ordering (no foreign keys in Phase 1).
