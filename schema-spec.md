# qmigrate — Schema DSL Specification

Version: 0.1 (Phase 1 design)
Status: Locked for Phase 1 implementation

This document is the canonical reference for the qmigrate native q schema DSL. It defines the public surface for declaring kdb+ table schemas, the internal representation those declarations produce, the validation rules, and the Phase 1 scope.

The DSL is one of two supported input formats. The other — Delta Control XML — produces the same internal representation and is covered by a separate spec.

---

## 1. Design principles

1. **Pure data.** Schema files have no side effects. Each file is a single expression returning a schema dict. Evaluating a file twice produces the same value.
2. **One file per table.** Each `.q` file under the schemas directory declares exactly one table. This gives precise git diffs and clear ownership.
3. **Native q vocabulary.** Type names, attribute symbols, and modifier keys are q-native. No translation layer.
4. **Q's natural syntax.** The DSL uses q's list syntax (parenthesised, semicolon-separated). No bespoke parser, no DSL-within-q tricks.
5. **Small surface.** Six public functions, four modifier keys. Easy to learn, hard to misuse.
6. **Explicit over implicit.** No magic. Attributes are declared not auto-applied. Defaults are stated not inferred. Errors are loud.

---

## 2. File layout

```
schemas/
  trade.q
  quote.q
  orderbook.q
  reference/
    instruments.q
    exchanges.q
```

The loader recursively walks the directory and evaluates each `*.q` file. Each file must be a single q expression evaluating to a schema dict (see §6). Filenames are not significant — the table name comes from the `.qm.schema` call inside the file. Convention is to name the file after the table.

---

## 3. Public API

Six functions total. All are pure (no side effects, no global state) except `.qm.loadSchemas`, which reads files.

### 3.1 Table-shape helpers

```q
.qm.partitioned[partField]    // partitioned HDB table; partField is a symbol
.qm.splayed[]                 // splayed (single-directory) table
.qm.memory[]                  // in-memory table
```

Each returns a small dict tagged as a table-shape declaration. A schema must include exactly one table-shape helper.

### 3.2 Column helpers

```q
.qm.col [name; type]              // column with no modifiers
.qm.colx[name; type; modifiers]   // column with modifier dict
```

- `name` is a symbol.
- `type` is one of the type symbols listed in §4.
- `modifiers` is a dict (see §5) or a 2-element symbol list as shorthand for a single-key dict.

Use `.qm.col` for plain columns. Use `.qm.colx` only when the column has modifiers. Mixing them in the same schema is expected and idiomatic.

### 3.3 Schema constructor

```q
.qm.schema[tableName; partsList]
```

- `tableName` is a symbol.
- `partsList` is a list of values returned by the helpers above.

Returns a normalised schema dict (see §6). Validates the parts list at call time; throws on any issue from §7.

### 3.4 Loader

```q
.qm.loadSchemas[dir]
```

- `dir` is a filepath symbol pointing at the schemas root.
- Recursively finds `*.q` files, evaluates each, validates results.
- Returns a dict keyed by table name, value is the schema dict.

This is the only function in the DSL with side effects (file I/O).

---

## 4. Type vocabulary

Type symbols are q-native. The full set accepted in Phase 1:

```
boolean  byte  short  int  long  real  float
char     symbol
timestamp  month  date  datetime  timespan  minute  second  time
guid
string
```

Notes:

- `string` is q sugar for "list of char." A `string` column cannot also have `\`list\`true` — it is already a list.
- All other types support both scalar and vector form (via the `list` modifier).
- Compound types (dicts in columns, tables in columns, lists of lists) are not supported in Phase 1.
- Unknown type symbols are rejected at parse time.

---

## 5. Modifier vocabulary

Modifiers are passed to `.qm.colx` as a dict. Phase 1 recognises exactly four keys:

| Key         | Type     | Meaning                                                     |
|-------------|----------|-------------------------------------------------------------|
| `attr`      | symbol   | Column attribute: `` `p ``, `` `s ``, `` `u ``, or `` `g `` |
| `default`   | any      | Literal value used to backfill the column on existing data  |
| `defaultFn` | symbol   | Reference to a q function for computed default values       |
| `list`      | boolean  | `1b` marks this as a vector column (each cell is a list)    |

Any other key is rejected at parse time.

### 5.1 Modifier shorthand

For a single modifier, a 2-element symbol list is accepted as shorthand for a single-key dict:

```q
.qm.colx[`sym; `symbol; `attr`p]
// equivalent to:
.qm.colx[`sym; `symbol; (enlist `attr)!enlist `p]
```

For two or more modifiers, an explicit dict is required:

```q
.qm.colx[`exchange; `symbol; `default`attr!(`NYSE;`g)]
```

### 5.2 Modifier semantics

**`attr`** — declares the intended attribute. qmigrate validates that the on-disk data satisfies the attribute (sorted for `s`, parted for `p`, unique for `u`) and applies the attribute marker. It does **not** sort, group, or de-duplicate data as a side effect. Data must be in the required shape before applying.

**`default`** — used only when adding a new column to an existing splayed or partitioned table. The value is broadcast to fill the new column. For scalar columns, the value must be of the column's type. For list columns (`\`list\`true`), the default is the value placed in each cell.

**`defaultFn`** — symbol of a function defined in the q session at apply time. Signature must be `{[path; columnName] returns vector}` where `path` is the partition directory (or table directory for splayed). Mutually exclusive with `default`. Resolved via `get` at apply time; missing references fail before any data is touched.

**`list`** — when `1b`, the column is a vector column. The element type is whatever `type` argument was given. Defaults for list columns: if `default` is omitted, new cells get an empty typed list of the element type. If `default` is set, that value goes in every new cell verbatim (e.g. `\`default enlist 0f` puts `enlist 0f` in each cell).

---

## 6. Internal representation

`.qm.schema` returns a dict with this shape:

```q
`name`kind`partitionField`columns ! (
  `trade;
  `partitioned;
  `date;
  ([] name:      `time      `sym       `price    `exchange;
      type:      `timestamp `symbol    `float    `symbol;
      list:      0b         0b         0b        0b;
      attr:      `          `p         `         `g;
      default:   (::       ; ::       ; ::      ; `NYSE);
      defaultFn: `          `          `         `
   )
  )
```

Fields:

- **`name`** — table name (symbol).
- **`kind`** — one of `` `partitioned ``, `` `splayed ``, `` `memory ``.
- **`partitionField`** — symbol if `kind` is `partitioned`, otherwise `` ` ``.
- **`columns`** — keyed table, one row per column, with fixed columns: `name`, `type`, `list`, `attr`, `default`, `defaultFn`. Absent modifiers are represented as: `attr` → `` ` ``, `default` → `::`, `defaultFn` → `` ` ``, `list` → `0b`.

This representation is identical for schemas sourced from the native q DSL and from Delta Control XML. The differ, plan, apply, and report layers know only this representation.

`.qm.loadSchemas` returns `dict[tableName → schemaDict]`.

---

## 7. Validation rules

`.qm.schema` validates its inputs and throws on any of the following. Each error message names the table and column where applicable.

### 7.1 Structural

- Empty `partsList` — schema has no entries.
- Zero table-shape helpers in `partsList`.
- More than one table-shape helper in `partsList`.
- Zero column helpers in `partsList`.
- Duplicate column names within a schema.
- `tableName` is not a symbol.

### 7.2 Types

- Unknown type symbol (not in §4).
- `type` is `` `string `` and modifier `list` is `1b`.

### 7.3 Modifiers

- Unknown modifier key (not in §5).
- `default` and `defaultFn` both set on the same column.
- `attr` value is not in `` `p`s`u`g ``.
- `list` value is not boolean.
- `defaultFn` value is not a symbol.
- Modifier shorthand list has length other than 2.

### 7.4 Loader-level (cross-schema)

`.qm.loadSchemas` additionally checks:

- Duplicate table names across files.
- Any file that fails to evaluate or does not return a valid schema dict.

---

## 8. Example schemas

### 8.1 Partitioned table

```q
// schemas/trade.q

.qm.schema[`trade] (
  .qm.partitioned[`date];

  .qm.col [`time;     `timestamp];
  .qm.colx[`sym;      `symbol;    `attr`p];
  .qm.col [`price;    `float];
  .qm.col [`size;     `long];
  .qm.colx[`exchange; `symbol;    `default`attr!(`NYSE;`g)]
  )
```

### 8.2 Splayed table

```q
// schemas/instruments.q

.qm.schema[`instruments] (
  .qm.splayed[];

  .qm.colx[`sym;    `symbol;  `attr`s];
  .qm.col [`name;   `symbol];
  .qm.col [`sector; `symbol];
  .qm.col [`active; `boolean]
  )
```

### 8.3 In-memory table

```q
// schemas/config.q

.qm.schema[`config] (
  .qm.memory[];

  .qm.colx[`key;   `symbol;  `attr`u];
  .qm.col [`value; `string]
  )
```

### 8.4 Vector columns

```q
// schemas/orderbook.q

.qm.schema[`orderbook] (
  .qm.partitioned[`date];

  .qm.col [`time;       `timestamp];
  .qm.colx[`sym;        `symbol;     `attr`p];
  .qm.colx[`bid_prices; `float;      `list`true];
  .qm.colx[`bid_sizes;  `long;       `list`true];
  .qm.colx[`ask_prices; `float;      `list`true];
  .qm.colx[`ask_sizes;  `long;       `list`true]
  )
```

### 8.5 Computed default

```q
// schemas/trade.q

.qm.schema[`trade] (
  .qm.partitioned[`date];

  .qm.col [`time;       `timestamp];
  .qm.col [`sym;        `symbol];
  .qm.col [`price;      `float];
  .qm.colx[`load_date;  `date;      `defaultFn`.user.computeLoadDate]
  )
```

The user supplies `.user.computeLoadDate` in the q session before calling apply:

```q
.user.computeLoadDate: {[path; col]
  // path is e.g. `:/data/hdb/2026.01.15/trade
  // return a vector of dates matching the row count
  count[get path] # "D"$-10#string path
  };
```

---

## 9. Enumerated symbols

For **partitioned tables**, every symbol column is assumed enumerated against the root HDB's `sym` file. This is the kdb+ standard pattern and the only mode supported in Phase 1.

Concretely:

- Schemas do not declare enumeration. A symbol column in a partitioned table is enumerated by default.
- Apply operations that introduce new symbol values extend the root `sym` file.
- Multi-sym-file domains and explicit opt-out of enumeration are Phase 2 work.

For **splayed and in-memory tables**, symbol columns are raw symbols. No enumeration.

If introspection of an existing HDB finds a symbol column that is not enumerated when it should be (or vice versa), the differ surfaces this as a warning, not a silent transformation.

---

## 10. Q syntax notes

A few reminders for users writing schema files:

- Inside `(...)`, statements are separated by `;`. The **last** statement has no trailing semicolon — this is a q rule, not a qmigrate rule.
- `.qm.partitioned[\`date]` and `.qm.partitioned \`date` are equivalent. Use whichever reads better.
- Whitespace inside the parens is freeform. The recommended style aligns column names and types vertically (see examples).
- Comments use `/` for line comments and `/` ... `\` for block comments.

---

## 11. Phase 1 scope

### In scope

- Splayed, partitioned, and in-memory tables.
- Scalar columns and vector columns (via `list` modifier).
- All q native types listed in §4.
- Column attributes declared and validated (`p`, `s`, `u`, `g`).
- Literal defaults and computed defaults.
- Root-sym-file enumeration for partitioned tables.

### Out of scope (Phase 1)

These will fail with a clear error if attempted:

- Foreign keys between tables.
- Nested list columns (lists of lists).
- Compound column types (dicts, tables in cells).
- Multi-sym-file enums and explicit enumeration control.
- Per-table compression settings.
- On-disk re-sorting of data as part of attribute application.
- Mixed schema sources for a single HDB.
- Writing Delta Control XML (read-only input).
- Foreign-key-style cross-table validation.

See the README for the full phase roadmap.

---

## 12. Version history

| Version | Date       | Notes                              |
|---------|------------|------------------------------------|
| 0.1     | 2026-05-27 | Initial Phase 1 specification.     |
