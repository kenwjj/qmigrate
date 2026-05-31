# Plan Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `.qm.plan`, a pure layer that turns a differ result plus the declared schemas into an ordered, executable migration plan.

**Architecture:** A new `src/plan.q` in namespace `.qm`, loaded after `src/diff.q`. One public entry `.qm.plan[differResult; declaredDict]` and two pure helpers `.qm.i.opFor` (one differ row → 0+ op rows) and `.qm.i.orderOps` (stable-sort into execution order, assign `seq`). No disk I/O. Tests live in a new hand-rolled `_smoke_plan.q` harness (no test framework is wired up in this repo yet).

**Tech Stack:** kdb+/q (KDB-X 5.0). Tests reuse the differ's own helpers — `.qm.i.row`, `.qm.i.rollupWith`, `.qm.i.normOpts`, `.qm.i.colInfo` — and the DSL (`.qm.schema`/`.qm.col`/`.qm.colx`) to build faithful inputs.

---

## Background the engineer needs

**Spec:** `docs/superpowers/specs/2026-05-31-plan-layer-design.md`. Read it. The op catalog (§3) and ordering (§4) are the heart of this work.

**What a differ result looks like** (output of `.qm.diff` / `.qm.diffTable`, defined in `src/diff.q`):

```q
`maxSeverity`applyable`rows ! (`destructive; 0b; <rows table>)
```

The `rows` table has columns `table column change from to severity detail`. One row per difference. `change` is one of the 12 catalog values; `from` is the on-disk value, `to` the declared value (either may be `::`).

**What a declared schema looks like** (section 6 rep, from `.qm.schema`, see `schema-spec.md` §6):

```q
`name`kind`partitionField`columns ! (`trade; `partitioned; `date; <columns table>)
```

The `columns` table has columns `name type list attr default defaultFn`. `.qm.loadSchemas` returns a dict `tableName -> this dict`; `.qm.plan` takes that whole dict.

**Reusable differ helpers** (already in `src/diff.q`, namespace `.qm.i`):

- `.qm.i.row[tbl;col;chg;frm;to;det]` → a 1-row **differ** rows table with severity auto-filled from the catalog. Use it in tests to fabricate diff rows.
- `.qm.i.rollupWith[rows;opts]` → wraps a rows table into a `` `maxSeverity`applyable`rows `` dict. Use it in tests to fabricate a whole differ result.
- `.qm.i.normOpts[opts]` → validates/defaults the opts dict.
- `.qm.i.noRows` → an empty differ rows table.
- `.qm.i.colInfo[colsTable;c]` → `` `type`list`attr`enum `` for one column.

**How to run the test harness** (from the repo root; sets the KDB-X license path — see README):

```
QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q
```

The harness exits non-zero on any failed check and prints `RESULT  ok=N fail=M` last.

**q reminders for this work:**
- Tables that hold dict-valued or string-valued cells are built with `flip name!cols`, **not** `([] ...)`. This repo already does this in `src/diff.q`.
- `each` over a table yields one **row dict** per iteration; inside, `row\`change` indexes a field.
- `~` is match (deep equality); `in` tests membership. `99h=type x` is true for a dict.
- A symbol-keyed dict indexed by a missing key is handled explicitly in code below (we never rely on its null behaviour).
- **Building a single-entry `declaredDict`:** use the list form `(enlist\`trade)!enlist schemaDict`, never the atom form `` `trade!schemaDict ``. In KDB-X, `atom!dict` produces a *keyed table* (type 112h), not a dict (99h), so it trips `.qm.plan`'s and `.qm.diff`'s dict guards. The `loadSchemas` path is unaffected (it always returns a real dict).

---

## File Structure

- **Create `src/plan.q`** — the whole plan layer (3 units in `.qm`, loaded after `diff.q`). One responsibility: turn a differ result + declared schemas into an ordered op table. No disk I/O.
- **Create `_smoke_plan.q`** — hand-rolled test harness for the plan layer. Mirrors `_smoke_diff.q` style (`chk`/`thr`, `exit fail`).
- **Modify `README.md`** — document the plan layer under a new "Plan" section and add `src/plan.q` / `_smoke_plan.q` to the Layout and Testing sections.

---

## Task 1: Scaffold `src/plan.q` and the harness; empty plan + input validation

**Files:**
- Create: `src/plan.q`
- Create: `_smoke_plan.q`

- [ ] **Step 1: Write the failing test harness**

Create `_smoke_plan.q`:

```q
/ Manual smoke check for the .qm plan layer (not a test framework — see memory).
/ Run: QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q

\l src/qm.q
\l src/diff.q
\l src/plan.q

ok:0; fail:0;
chk:{[d;c] $[c; [ok+:1; -1 "  ok   ",d]; [fail+:1; -1 "  FAIL ",d]] };
thr:{[f;a] 1b~@[f;a;{[e]1b}] };               / true if f[a] signals

-1 "--- plan: empty diff ---";
dr0:.qm.i.rollupWith[.qm.i.noRows; .qm.i.normOpts[()!()]];
p0:.qm.plan[dr0; ()!()];
chk["empty plan result dict"; `maxSeverity`applyable`ops~key p0];
chk["empty plan 0 ops";       0=count p0`ops];
chk["empty plan applyable";   p0[`applyable]~1b];
chk["empty plan maxSeverity"; p0[`maxSeverity]~`ok];

-1 "--- plan: input validation ---";
chk["plan malformed dr throws"; thr[.qm.plan[(enlist`bogus)!enlist 1; ]; ()!()]];
chk["plan non-dict decls throws"; thr[.qm.plan[dr0; ]; 42]];

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: error loading `src/plan.q` (file does not exist yet), or `'.qm.plan` undefined.

- [ ] **Step 3: Create `src/plan.q` with the infrastructure and a stub `opFor`**

Create `src/plan.q`:

```q
/ qmigrate — plan layer (Phase 1)
/ Spec: docs/superpowers/specs/2026-05-31-plan-layer-design.md
//
/ Consumes a differ result (.qm.diff output) + the declared schemas and
/ produces an ordered, pure migration plan. No disk I/O.
/ Public: .qm.plan        Pure helpers: .qm.i.opFor .qm.i.orderOps

\d .qm

/ empty ops table (correct column types; seq filled by orderOps).
/ flip (not ([]...)) because `params holds dict cells and `detail holds strings.
i.noOps:0#flip `seq`table`column`op`change`severity`detail`params!(
  `long$(); `$(); `$(); `$(); `$(); `$(); (); ());

/ build a 1-row op table
i.op:{[tbl;col;op;chg;sev;det;prm]
  flip `seq`table`column`op`change`severity`detail`params!(
    enlist 0N; enlist tbl; enlist col; enlist op; enlist chg; enlist sev; enlist det; enlist prm) };

/ pull a declared column's full spec out of a section-6 columns table
i.declCol:{[ct;c]
  idx:first where ct[`name]=c;
  `type`list`attr`default`defaultFn!(
    ct[`type]idx; ct[`list]idx; ct[`attr]idx; ct[`default]idx; ct[`defaultFn]idx) };

/ map one differ row -> 0+ plan op rows. decl is the table's schema dict, or (::) if undeclared.
i.opFor:{[decl;row]
  chg:row`change; tbl:row`table; col:row`column; sev:row`severity;
  / branches added per task; default: no op
  i.noOps };

/ intra-table op precedence (spec section 4)
i.opRank:`createTable`addColumn`dropColumn`setAttr`clearAttr`reEnumerate`reorderColumns`manual!til 8;

/ stable-order ops by (table first-appearance, op precedence); assign seq 1..n
i.orderOps:{[ops]
  if[0=count ops; :ops];
  ti:(distinct ops`table)?ops`table;          / table first-appearance index
  ops:ops iasc (100*ti)+i.opRank ops`op;
  update seq:`long$1+til count ops from ops };

/ public: build a migration plan from a differ result + declared schemas
plan:{[dr;dd]
  if[not all `maxSeverity`applyable`rows in key dr;
     '"qm: plan: malformed differ result"];
  if[not 99h=type dd; '"qm: plan: declaredDict must be a dict"];
  rows:dr`rows;
  declFor:{[dd;t] $[t in key dd; dd t; ::]};
  ops:i.orderOps raze enlist[i.noOps],
        {[dd;declFor;r] i.opFor[declFor[dd;r`table]; r]}[dd;declFor] each rows;
  `maxSeverity`applyable`ops!(dr`maxSeverity; dr`applyable; ops) };

\d .
```

- [ ] **Step 4: Run the harness to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, final line `RESULT  ok=6 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/plan.q _smoke_plan.q
git commit -m "feat(plan): scaffold plan layer with empty-plan + input validation"
```

---

## Task 2: `newTable` → `createTable`

**Files:**
- Modify: `src/plan.q` (`i.opFor`)
- Modify: `_smoke_plan.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q`, immediately before the final `-1 "";` block:

```q
-1 "--- plan: createTable ---";
/ a declared table absent on disk -> differ emits a single newTable row
dtrade:.qm.schema[`trade] (
  .qm.partitioned[`date];
  .qm.col [`time;  `timestamp];
  .qm.colx[`sym;   `symbol; `attr`p];
  .qm.col [`price; `float] );
drNew:.qm.i.rollupWith[.qm.i.row[`trade;`;`newTable;::;`partitioned;"absent"]; .qm.i.normOpts[()!()]];
pNew:.qm.plan[drNew; `trade!dtrade];
chk["createTable 1 op";        1=count pNew`ops];
chk["createTable op type";     `createTable~first pNew[`ops]`op];
chk["createTable seq=1";       1=first pNew[`ops]`seq];
chk["createTable table-level"; `~first pNew[`ops]`column];
chk["createTable params kind"; `partitioned~(first pNew[`ops]`params)`kind];
chk["createTable params cols"; `time`sym`price~(first pNew[`ops]`params)[`columns]`name];
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: the new `createTable` checks FAIL (0 ops produced; `opFor` still returns `i.noOps`).

- [ ] **Step 3: Add the `createTable` branch to `i.opFor`**

In `src/plan.q`, replace the body of `i.opFor` (the `/ branches added per task` comment and the `i.noOps` line) with:

```q
  $[chg~`newTable;
      i.op[tbl;`;`createTable;chg;sev;
           "create ",string[decl`kind]," table ",string tbl;
           `kind`partitionField`columns!(decl`kind; decl`partitionField; decl`columns)];
    / unmanagedTable, skipped, unknown -> no op
    i.noOps ] };
```

(The `$[ ... ; i.noOps ]` is a growing conditional; later tasks insert more `chg~...; <expr>;` branches before the `/ unmanagedTable` comment.)

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=12 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/plan.q _smoke_plan.q
git commit -m "feat(plan): createTable op for newTable"
```

---

## Task 3: `addColumn` → `addColumn` (with default / defaultFn in params)

**Files:**
- Modify: `src/plan.q` (`i.opFor`)
- Modify: `_smoke_plan.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q` before the final block:

```q
-1 "--- plan: addColumn ---";
/ declared trade with a literal default and a computed default; differ says both are addColumn
dadd:.qm.schema[`trade] (
  .qm.partitioned[`date];
  .qm.col [`time;     `timestamp];
  .qm.colx[`exchange; `symbol; `default`attr!(`NYSE;`g)];
  .qm.colx[`load_date;`date;   `defaultFn`.user.computeLoadDate] );
rowsAdd:(.qm.i.row[`trade;`exchange; `addColumn;::;`symbol;"add"]),
        (.qm.i.row[`trade;`load_date;`addColumn;::;`date;  "add"]);
pAdd:.qm.plan[.qm.i.rollupWith[rowsAdd; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist dadd];
ax:select from pAdd[`ops] where column=`exchange;
chk["addColumn op type";       `addColumn~first ax`op];
chk["addColumn carries default";`NYSE~(first ax`params)`default];
chk["addColumn carries attr";   `g~(first ax`params)`attr];
al:select from pAdd[`ops] where column=`load_date;
chk["addColumn defaultFn param";`.user.computeLoadDate~(first al`params)`defaultFn];
chk["addColumn defaultFn detail"; (first al`detail) like "*computed default via*"];
chk["addColumn two ops";        2=count select from pAdd[`ops] where op=`addColumn];
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: the new `addColumn` checks FAIL (no op produced for `addColumn`).

- [ ] **Step 3: Add the `addColumn` branch to `i.opFor`**

In `src/plan.q`, insert this branch into the `$[...]` in `i.opFor`, immediately before the `/ unmanagedTable, skipped, unknown -> no op` comment:

```q
    chg~`addColumn;
      [ci:i.declCol[decl`columns;col];
       i.op[tbl;col;`addColumn;chg;sev;
            "add column ",string[col]," (",string[ci`type],")",
              $[not ci[`defaultFn]~`; ", computed default via ",string ci`defaultFn;
                not ci[`default]~(::); ", default ",$[10h=type ci`default; ci`default; string ci`default];
                ""];
            ci]];
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=19 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/plan.q _smoke_plan.q
git commit -m "feat(plan): addColumn op carrying default/defaultFn/attr"
```

---

## Task 4: `attrChange` → `setAttr` / `clearAttr`

**Files:**
- Modify: `src/plan.q` (`i.opFor`)
- Modify: `_smoke_plan.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q` before the final block:

```q
-1 "--- plan: attrChange ---";
dattr:.qm.schema[`trade] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`p]; .qm.col[`px;`float]);
/ declared attr `p, disk none -> setAttr ; declared none, disk `g -> clearAttr
rowsAttr:(.qm.i.row[`trade;`sym;`attrChange;`;`p;"attr differs"]),
         (.qm.i.row[`trade;`px; `attrChange;`g;`;"attr differs"]);
pAttr:.qm.plan[.qm.i.rollupWith[rowsAttr; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist dattr];
chk["setAttr op";    `setAttr in exec op from pAttr[`ops] where column=`sym];
chk["setAttr param"; `p~(first exec params from pAttr[`ops] where column=`sym)`attr];
chk["clearAttr op";  `clearAttr in exec op from pAttr[`ops] where column=`px];
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: the new `attrChange` checks FAIL.

- [ ] **Step 3: Add the `attrChange` branch to `i.opFor`**

Insert before the `/ unmanagedTable` comment in `i.opFor`:

```q
    chg~`attrChange;
      $[(row`to)~`;
         i.op[tbl;col;`clearAttr;chg;sev;
              "clear attribute on ",string col;(enlist`from)!enlist row`from];
         i.op[tbl;col;`setAttr;chg;sev;
              "apply `",string[row`to]," attribute to ",string col;(enlist`attr)!enlist row`to]];
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=22 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/plan.q _smoke_plan.q
git commit -m "feat(plan): setAttr/clearAttr ops for attrChange"
```

---

## Task 5: `dropColumn` → `dropColumn` (destructive)

**Files:**
- Modify: `src/plan.q` (`i.opFor`)
- Modify: `_smoke_plan.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q` before the final block:

```q
-1 "--- plan: dropColumn ---";
ddrop:.qm.schema[`trade] (.qm.splayed[]; .qm.col[`keep;`long]);
pDrop:.qm.plan[.qm.i.rollupWith[.qm.i.row[`trade;`gone;`dropColumn;`float;::;"on disk, not declared"]; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist ddrop];
chk["dropColumn op";       `dropColumn~first pDrop[`ops]`op];
chk["dropColumn destructive"; `destructive~first pDrop[`ops]`severity];
chk["dropColumn column";   `gone~first pDrop[`ops]`column];
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: the new `dropColumn` checks FAIL.

- [ ] **Step 3: Add the `dropColumn` branch to `i.opFor`**

Insert before the `/ unmanagedTable` comment in `i.opFor`:

```q
    chg~`dropColumn;
      i.op[tbl;col;`dropColumn;chg;sev;
           "drop column ",string[col]," from disk";()!()];
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=25 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/plan.q _smoke_plan.q
git commit -m "feat(plan): dropColumn op (destructive)"
```

---

## Task 6: `colOrderChange` → `reorderColumns`

**Files:**
- Modify: `src/plan.q` (`i.opFor`)
- Modify: `_smoke_plan.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q` before the final block:

```q
-1 "--- plan: reorderColumns ---";
dord:.qm.schema[`trade] (.qm.splayed[]; .qm.col[`a;`long]; .qm.col[`b;`long]);
pOrd:.qm.plan[.qm.i.rollupWith[.qm.i.row[`trade;`;`colOrderChange;`b`a;`a`b;"different order"]; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist dord];
chk["reorderColumns op";    `reorderColumns~first pOrd[`ops]`op];
chk["reorderColumns order"; `a`b~(first pOrd[`ops]`params)`order];
chk["reorderColumns table-level"; `~first pOrd[`ops]`column];
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: the new `reorderColumns` checks FAIL.

- [ ] **Step 3: Add the `colOrderChange` branch to `i.opFor`**

Insert before the `/ unmanagedTable` comment in `i.opFor`:

```q
    chg~`colOrderChange;
      i.op[tbl;`;`reorderColumns;chg;sev;
           "rewrite .d to declared column order";(enlist`order)!enlist decl[`columns]`name];
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=28 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/plan.q _smoke_plan.q
git commit -m "feat(plan): reorderColumns op for colOrderChange"
```

---

## Task 7: `enumMismatch` → `reEnumerate`

**Files:**
- Modify: `src/plan.q` (`i.opFor`)
- Modify: `_smoke_plan.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q` before the final block:

```q
-1 "--- plan: reEnumerate ---";
denum:.qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`sym;`symbol]);
/ differ enumMismatch row: to=1b (declared enum expected), from=0b (disk raw)
pEnum:.qm.plan[.qm.i.rollupWith[.qm.i.row[`trade;`sym;`enumMismatch;0b;1b;"enumeration state differs"]; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist denum];
chk["reEnumerate op";       `reEnumerate~first pEnum[`ops]`op];
chk["reEnumerate warning";  `warning~first pEnum[`ops]`severity];
chk["reEnumerate param";    1b~(first pEnum[`ops]`params)`enumerate];
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: the new `reEnumerate` checks FAIL.

- [ ] **Step 3: Add the `enumMismatch` branch to `i.opFor`**

Insert before the `/ unmanagedTable` comment in `i.opFor`:

```q
    chg~`enumMismatch;
      i.op[tbl;col;`reEnumerate;chg;sev;
           "re-enumerate ",string col;(enlist`enumerate)!enlist row`to];
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=31 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/plan.q _smoke_plan.q
git commit -m "feat(plan): reEnumerate op for enumMismatch"
```

---

## Task 8: recreate-class changes → `manual`

**Files:**
- Modify: `src/plan.q` (`i.opFor`)
- Modify: `_smoke_plan.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q` before the final block:

```q
-1 "--- plan: manual (recreate-class) ---";
dman:.qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`a;`long]);
rowsMan:(.qm.i.row[`trade;`a;`typeChange;`float;`long;"type differs"]),
        (.qm.i.row[`trade;`a;`listChange;0b;1b;"list-ness differs"]),
        (.qm.i.row[`trade;`;`kindChange;`splayed;`partitioned;"kind differs"]),
        (.qm.i.row[`trade;`;`partitionChange;`month;`date;"partition differs"]);
pMan:.qm.plan[.qm.i.rollupWith[rowsMan; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist dman];
chk["manual for all 4 recreate changes"; 4=count select from pMan[`ops] where op=`manual];
chk["manual keeps destructive sev"; all `destructive=exec severity from pMan[`ops] where op=`manual];
chk["manual carries originating change"; `typeChange in exec change from pMan[`ops] where op=`manual];
chk["manual detail mentions recreate"; all (exec detail from pMan[`ops] where op=`manual) like "*drop-and-recreate*"];
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: the new `manual` checks FAIL.

- [ ] **Step 3: Add the `manual` branch to `i.opFor`**

Insert before the `/ unmanagedTable` comment in `i.opFor`:

```q
    chg in `typeChange`listChange`kindChange`partitionChange;
      i.op[tbl;col;`manual;chg;sev;
           string[chg]," requires drop-and-recreate (Phase 2)";()!()];
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=35 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/plan.q _smoke_plan.q
git commit -m "feat(plan): flag recreate-class changes as manual ops"
```

---

## Task 9: ordering, `seq`, and no-op changes

**Files:**
- Modify: `_smoke_plan.q`

This task adds assertions only — `i.orderOps` and the no-op fallback were implemented in Tasks 1–8. It verifies intra-table ordering (§4) and that `unmanagedTable`/`skipped` produce no ops.

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q` before the final block:

```q
-1 "--- plan: ordering + no-ops ---";
dmix:.qm.schema[`trade] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`p]; .qm.col[`new;`long]; .qm.col[`keep;`long]);
/ one table, several changes given to the differ OUT of execution order
rowsMix:(.qm.i.row[`trade;`;`colOrderChange;`keep`sym;`sym`new`keep;"order"]),
        (.qm.i.row[`trade;`gone;`dropColumn;`float;::;"drop"]),
        (.qm.i.row[`trade;`new;`addColumn;::;`long;"add"]),
        (.qm.i.row[`trade;`sym;`attrChange;`;`p;"attr"]);
pMix:.qm.plan[.qm.i.rollupWith[rowsMix; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist dmix];
chk["ordering: seq is 1..n";  pMix[`ops][`seq]~`long$1+til count pMix`ops];
chk["ordering: op sequence";  pMix[`ops][`op]~`addColumn`dropColumn`setAttr`reorderColumns];

-1 "--- plan: unmanaged + skipped produce no op ---";
dnone:.qm.schema[`cfg] (.qm.memory[]; .qm.col[`k;`symbol]);
rowsNone:(.qm.i.row[`ref;`;`unmanagedTable;`ref;::;"on disk, not declared"]),
         (.qm.i.row[`cfg;`;`skipped;::;::;"in-memory table; no disk target"]);
pNone:.qm.plan[.qm.i.rollupWith[rowsNone; .qm.i.normOpts[()!()]]; (enlist`cfg)!enlist dnone];
chk["unmanaged+skipped -> 0 ops"; 0=count pNone`ops];
```

- [ ] **Step 2: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=38 fail=0`. (These should pass immediately — the behaviour is already implemented. If `ordering: op sequence` fails, inspect `i.opRank` order in `src/plan.q` against spec §4.)

- [ ] **Step 3: Commit**

```
git add _smoke_plan.q
git commit -m "test(plan): assert intra-table ordering and no-op changes"
```

---

## Task 10: end-to-end (`.qm.diff` → `.qm.plan`) and `applyable` propagation

**Files:**
- Modify: `_smoke_plan.q`

Verifies the wiring from a real differ run on a temporary on-disk HDB, and that `applyable` is carried through (including the `allowDestructive` opt-in applied at the differ).

- [ ] **Step 1: Write the failing test**

Add to `_smoke_plan.q` before the final block:

```q
-1 "--- plan: end-to-end against a temp HDB ---";
HDB:`:testhdb_plan;
/ build a splayed `inst on disk: sym (no attr), name
system "mkdir ",ssr[1_string ` sv HDB,`inst,`; "/"; "\\"];
(` sv HDB,`inst,`sym)  set `AA`BB;
(` sv HDB,`inst,`name) set `x`y;
(` sv HDB,`inst,`.d)   set `sym`name;
/ declared inst: add `active (bool, default 0b), set `s attr on sym
/ note: `default must carry a real boolean here; the `list`true symbol-shorthand
/ coercion in qm.q applies only to the `list key, not to `default.
dinst:.qm.schema[`inst] (
  .qm.splayed[];
  .qm.colx[`sym;    `symbol; `attr`s];
  .qm.col [`name;   `symbol];
  .qm.colx[`active; `boolean; (enlist`default)!enlist 0b] );
drE:.qm.diff[HDB; (enlist`inst)!enlist dinst; ()!()];
pE:.qm.plan[drE; (enlist`inst)!enlist dinst];
chk["e2e addColumn active"; `addColumn in exec op from pE[`ops] where column=`active];
chk["e2e setAttr sym";      `setAttr in exec op from pE[`ops] where column=`sym];
chk["e2e applyable";        pE[`applyable]~1b];

-1 "--- plan: destructive applyable propagation ---";
/ declared inst that drops `name on disk -> destructive
ddrp:.qm.schema[`inst] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`s]);
drD:.qm.diff[HDB; (enlist`inst)!enlist ddrp; ()!()];
pD:.qm.plan[drD; (enlist`inst)!enlist ddrp];
chk["e2e destructive blocked"; pD[`applyable]~0b];
chk["e2e dropColumn name";     `dropColumn in exec op from pD[`ops] where column=`name];
drDok:.qm.diff[HDB; (enlist`inst)!enlist ddrp; (enlist`allowDestructive)!enlist 1b];
pDok:.qm.plan[drDok; (enlist`inst)!enlist ddrp];
chk["e2e applyable when allowed"; pDok[`applyable]~1b];

/ remove the throwaway HDB so re-runs start clean
@[{system $[.z.o like "w*"; "rmdir /s /q testhdb_plan"; "rm -rf testhdb_plan"]};::;{}];
```

- [ ] **Step 2: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: all checks `ok`, `RESULT  ok=44 fail=0`.

- [ ] **Step 3: Commit**

```
git add _smoke_plan.q
git commit -m "test(plan): end-to-end diff->plan and applyable propagation"
```

---

## Task 11: document the plan layer in the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Plan" section to the README**

In `README.md`, immediately after the `## Differ` section (it ends with the `.qm.diffTable` design-doc link, before `## Layout`), insert:

````markdown
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

Each row of `plan`ops` is one operation, ordered for execution (`seq` 1..n).
Recreate-class changes (`typeChange`/`listChange`/`kindChange`/`partitionChange`)
appear as `manual` operations — visible flags that a drop-and-recreate is needed
(Phase 2), not executable steps. The plan layer only sequences — the apply layer
(later) executes. Design:
**[docs/superpowers/specs/2026-05-31-plan-layer-design.md](docs/superpowers/specs/2026-05-31-plan-layer-design.md)**.
````

- [ ] **Step 2: Add the new files to the Layout section**

In `README.md`, in the `## Layout` code block, after the `src/diff.q` line add:

```
src/plan.q        the plan layer (.qm.plan); loaded after diff.q
```

and after the `_smoke_diff.q` line add:

```
_smoke_plan.q     manual verification check for the plan layer
```

- [ ] **Step 3: Update the Testing section**

In `README.md`, in the `## Testing` paragraph, after the sentence describing `_smoke_diff.q`, add:

```
`_smoke_plan.q` covers the plan layer — it builds differ results (both hand-built
and from a throwaway HDB) and asserts every operation in the catalog, the
execution ordering, and `applyable` propagation. Run with
`QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`.
```

- [ ] **Step 4: Update the status line**

In `README.md`, change the status blockquote near the top from:

```
> **Status:** Phase 1, in development. The native q schema DSL and the differ are implemented and verified; the plan / apply / report layers are not yet built.
```

to:

```
> **Status:** Phase 1, in development. The native q schema DSL, the differ, and the plan layer are implemented and verified; the apply / report layers are not yet built.
```

- [ ] **Step 5: Verify the smoke check still passes and commit**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q`
Expected: `RESULT  ok=44 fail=0` (README changes don't affect tests; this just confirms nothing broke).

```
git add README.md
git commit -m "docs(plan): document the plan layer in the README"
```

---

## Final verification

- [ ] Run the full plan harness: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q` → `RESULT  ok=44 fail=0`.
- [ ] Run the differ harness to confirm no regression: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q` → `fail=0`.
- [ ] Run the DSL harness: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke.q -q` → `fail=0`.
```
```
