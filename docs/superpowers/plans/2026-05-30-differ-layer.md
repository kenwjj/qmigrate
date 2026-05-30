# Differ Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `.qm.diff` / `.qm.diffTable` — compare a declared schema (the section-6 internal rep) against an on-disk HDB and emit a classified set of differences.

**Architecture:** A pure comparison core (`.qm.i.compare`, built from `i.cmpCols`/`i.cmpTable`/`i.cmpEnum`) plus a filesystem introspector (`.qm.i.introspect`) that reads on-disk tables via `meta` on memory-mapped directories. Public entry points (`diffTable`, `diff`) glue introspection + comparison + a severity rollup. A whole-HDB wrapper adds table-level add/unmanaged detection.

**Tech Stack:** q / kdb+ (KDB-X 5.0). No test framework yet — verification uses the hand-rolled smoke-harness style established in `_smoke.q` (`chk`/`thr` helpers, process exits non-zero on any failed assertion). Per the project's standing decision tests are not written strictly-first, but **every task ends with a smoke run that must pass before committing.**

**Reference spec:** `docs/superpowers/specs/2026-05-30-differ-design.md`

**Run command (used in every "run" step):**
```
QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q
```
(Empty `QLIC` causes `'license error: k4.lic`; `type`/`attr`/`from` are reserved words; a lone `/` line is a block comment — see `src/qm.q` for the conventions this code follows.)

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/diff.q` | The differ. Namespace `.qm`. Loaded after `src/qm.q`. Holds the change/severity tables, the pure compare helpers, the introspector, the rollup, and the two public functions. |
| `_smoke_diff.q` | Verification harness. Loads `src/qm.q` then `src/diff.q`. Builds a throwaway on-disk HDB fixture, runs the differ, asserts rows / `maxSeverity` / `applyable`. |

`src/diff.q` is one focused file (~150 lines); splitting introspection out is unnecessary at this size and the units are already separated by namespace (`.qm.i.*`).

---

## Result and row shapes (reference — defined in Task 1)

A diff **row table** has columns: `table` (sym), `column` (sym, `` ` `` for table-level), `change` (sym from the catalog), `from` (on-disk value or `::`), `to` (declared value or `::`), `severity` (sym), `detail` (string). Built via `flip` because `from` is a reserved word and cannot be a `([]...)` column token.

A **result dict** is `` `maxSeverity`applyable`rows!(ms;ap;rows) `` where `ms` is the highest severity present and `ap` is `0b` iff a destructive row is present and `allowDestructive` is not set.

The **actual rep** returned by `introspect` is the section-6 schema dict with one extra column in its `columns` table: `enum` (boolean — whether the on-disk column is enumerated). The declared rep has no `enum` column; declared enum-ness is derived (partitioned + symbol ⇒ enumerated).

---

## Task 0: Scaffold `src/diff.q` + smoke harness

**Files:**
- Create: `src/diff.q`
- Create: `_smoke_diff.q`

- [ ] **Step 1: Create `src/diff.q` with the namespace header and load-check stub**

```q
/ qmigrate — differ layer (Phase 1)
/ Spec: docs/superpowers/specs/2026-05-30-differ-design.md
//
/ Compares a declared schema (section-6 rep) against an on-disk HDB.
/ Public (read disk): .qm.diff .qm.diffTable
/ Pure core:          .qm.i.compare .qm.i.rollupWith

\d .qm

/ severity ordering (low -> high)
i.sevRank:`ok`change`warning`destructive!0 1 2 3;

\d .
```

- [ ] **Step 2: Create `_smoke_diff.q` harness skeleton**

```q
/ Manual smoke check for the .qm differ (not a test framework — see memory).
/ Run: QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q

\l src/qm.q
\l src/diff.q

ok:0; fail:0;
chk:{[d;c] $[c; [ok+:1; -1 "  ok   ",d]; [fail+:1; -1 "  FAIL ",d]] };
thr:{[f;a] 1b~@[f;a;{[e]1b}] };               / true if f[a] signals

-1 "--- scaffold ---";
chk["diff.q loaded"; `i.sevRank in key `.qm];

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
```

- [ ] **Step 3: Run the harness**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: prints `ok   diff.q loaded` and `RESULT  ok=1 fail=0`, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add src/diff.q _smoke_diff.q
git commit -m "feat(differ): scaffold diff.q and smoke harness"
```

---

## Task 1: Row builder, change catalog, and `compare` skeleton

**Files:**
- Modify: `src/diff.q`
- Modify: `_smoke_diff.q`

- [ ] **Step 1: Add the change→severity table, row builder, empty-rows template, and `compare` with stub helpers**

Insert into `src/diff.q` inside the `\d .qm` block, after `i.sevRank`:

```q
/ change-type -> severity (spec section 4)
i.changeSev:(`newTable`unmanagedTable`addColumn`attrChange`colOrderChange`dropColumn`typeChange`listChange`kindChange`partitionChange`enumMismatch`skipped)!
            `change`warning`change`change`change`destructive`destructive`destructive`destructive`destructive`warning`ok;

/ build a 1-row diff table. flip (not ([]...)) because `from is reserved.
i.row:{[tbl;col;chg;frm;t;det]
  flip `table`column`change`from`to`severity`detail!(
    enlist tbl; enlist col; enlist chg; enlist frm; enlist t; enlist i.changeSev chg; enlist det) };

/ empty rows table with the right columns
i.noRows:0#i.row[`;`;`skipped;::;::;""];

/ comparison helpers — filled in later tasks; stubbed to emit nothing for now
i.cmpCols:{[declared;actual] i.noRows };
i.cmpTable:{[declared;actual] i.noRows };
i.cmpEnum:{[declared;actual] i.noRows };

/ compare two section-6 reps. actual is (::) when the table is absent on disk.
i.compare:{[declared;actual]
  nm:declared`name;
  if[(::)~actual; :i.row[nm;`;`newTable;::;declared`kind;"table not present on disk"]];
  raze (i.cmpTable[declared;actual]; i.cmpCols[declared;actual]; i.cmpEnum[declared;actual]) };
```

- [ ] **Step 2: Add smoke assertions for the newTable path**

Replace the `--- scaffold ---` block in `_smoke_diff.q` with:

```q
-1 "--- compare: newTable ---";
d:.qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`a;`long]);
r:.qm.i.compare[d; ::];
chk["newTable 1 row";      1=count r];
chk["newTable change";     (first r)[`change]~`newTable];
chk["newTable severity";   (first r)[`severity]~`change];
chk["newTable to=kind";    (first r)[`to]~`partitioned];
```

- [ ] **Step 3: Run**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: 4 `ok` lines, `RESULT  ok=4 fail=0`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/diff.q _smoke_diff.q
git commit -m "feat(differ): row builder, change catalog, compare skeleton"
```

---

## Task 2: Column-level comparison (`i.cmpCols`)

**Files:**
- Modify: `src/diff.q`
- Modify: `_smoke_diff.q`

- [ ] **Step 1: Implement `i.colInfo` and `i.cmpCols`**

Replace the `i.cmpCols` stub in `src/diff.q` with:

```q
/ pull one column's fields out of a columns table as a dict
i.colInfo:{[ct;c]
  i:first where ct[`name]=c;
  `type`list`attr`enum!(ct[`type]i; ct[`list]i; ct[`attr]i; $[`enum in cols ct; ct[`enum]i; 0b]) };

/ add / drop / type / list / attr  (spec section 4)
i.cmpCols:{[declared;actual]
  nm:declared`name;
  dc:declared`columns; ac:actual`columns;
  dn:dc`name; an:ac`name;
  adds:dn except an;
  drops:an except dn;
  common:dn inter an;
  rows:i.noRows;
  rows,:raze {[nm;dc;c] i.row[nm;c;`addColumn;::;(i.colInfo[dc;c])`type;"declared, absent on disk"]}[nm;dc] each adds;
  rows,:raze {[nm;ac;c] i.row[nm;c;`dropColumn;(i.colInfo[ac;c])`type;::;"on disk, not declared"]}[nm;ac] each drops;
  rows,:raze {[nm;dc;ac;c]
    di:i.colInfo[dc;c]; ai:i.colInfo[ac;c];
    r:i.noRows;
    if[not di[`type]~ai`type; r,:i.row[nm;c;`typeChange;ai`type;di`type;"type differs"]];
    if[not di[`list]~ai`list; r,:i.row[nm;c;`listChange;ai`list;di`list;"list-ness differs"]];
    if[not di[`attr]~ai`attr; r,:i.row[nm;c;`attrChange;ai`attr;di`attr;"attribute differs"]];
    r }[nm;dc;ac] each common;
  rows };
```

- [ ] **Step 2: Add smoke assertions using hand-built section-6 reps**

Append to `_smoke_diff.q` before the RESULT block:

```q
-1 "--- compare: columns ---";
/ helper to build a section-6 columns table (with enum) for tests
mkcols:{[names;types;lists;attrs;enums]
  flip `name`type`list`attr`default`defaultFn`enum!(
    names; types; lists; attrs; count[names]#(::); count[names]#`; enums) };
mkrep:{[nm;kind;pf;cols] `name`kind`partitionField`columns!(nm;kind;pf;cols) };

/ declared: a(long) b(symbol,attr g) c(float,list)
decl:mkrep[`t;`splayed;`] mkcols[`a`b`c; `long`symbol`float; 000b; ``g`; 000b];
/ actual on disk: a(long) b(symbol,no attr) d(int)  -> add c, drop d, attrChange b
act :mkrep[`t;`splayed;`] mkcols[`a`b`d; `long`symbol`int;  000b; ```; 000b];
rc:.qm.i.cmpCols[decl;act];
chk["cmpCols addColumn c";  `addColumn in exec change from rc where column=`c];
chk["cmpCols dropColumn d";  `dropColumn in exec change from rc where column=`d];
chk["cmpCols attrChange b";  `attrChange in exec change from rc where column=`b];
chk["cmpCols no typeChange";  0=count select from rc where change=`typeChange];

/ typeChange + listChange on column a
decl2:mkrep[`t;`splayed;`] mkcols[enlist`a; enlist`float; enlist 1b; enlist`; enlist 0b];
act2 :mkrep[`t;`splayed;`] mkcols[enlist`a; enlist`long;  enlist 0b; enlist`; enlist 0b];
rc2:.qm.i.cmpCols[decl2;act2];
chk["cmpCols typeChange a";  `typeChange in exec change from rc2 where column=`a];
chk["cmpCols listChange a";  `listChange in exec change from rc2 where column=`a];
chk["cmpCols typeChange sev";`destructive in exec severity from rc2 where change=`typeChange];
```

Note: `exec change from rc where column=`c` is safe qSQL — `change`, `column` are not reserved. Never `exec type from`/`exec from from` (reserved); use functional indexing if you need those columns.

- [ ] **Step 3: Run**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: all prior + 7 new `ok` lines, `fail=0`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/diff.q _smoke_diff.q
git commit -m "feat(differ): column add/drop/type/list/attr comparison"
```

---

## Task 3: Table-level comparison + enumeration (`i.cmpTable`, `i.cmpEnum`)

**Files:**
- Modify: `src/diff.q`
- Modify: `_smoke_diff.q`

- [ ] **Step 1: Implement `i.cmpTable` (kind / partition / column order)**

Replace the `i.cmpTable` stub with:

```q
i.cmpTable:{[declared;actual]
  nm:declared`name;
  rows:i.noRows;
  if[not declared[`kind]~actual`kind;
     rows,:i.row[nm;`;`kindChange;actual`kind;declared`kind;"table kind differs"]];
  if[(declared[`kind]=`partitioned) & not declared[`partitionField]~actual`partitionField;
     rows,:i.row[nm;`;`partitionChange;actual`partitionField;declared`partitionField;"partition field differs"]];
  dn:declared[`columns]`name; an:actual[`columns]`name;
  common:dn inter an;
  dco:dn where dn in common;     / declared relative order of common cols
  aco:an where an in common;     / on-disk relative order of common cols
  if[not dco~aco;
     rows,:i.row[nm;`;`colOrderChange;aco;dco;"common columns in different order"]];
  rows };
```

- [ ] **Step 2: Implement `i.cmpEnum`**

Replace the `i.cmpEnum` stub with:

```q
/ enumeration mismatch (spec section 9): partitioned symbol cols are enum-by-default
i.cmpEnum:{[declared;actual]
  nm:declared`name;
  dc:declared`columns; ac:actual`columns;
  common:(dc`name) inter ac`name;
  declEnum:declared[`kind]=`partitioned;
  raze {[nm;dc;ac;declEnum;c]
    di:i.colInfo[dc;c]; ai:i.colInfo[ac;c];
    if[not di[`type]=`symbol; :i.noRows];
    if[declEnum~ai`enum; :i.noRows];
    i.row[nm;c;`enumMismatch;ai`enum;declEnum;"enumeration state differs"]
   }[nm;dc;ac;declEnum] each common };
```

- [ ] **Step 3: Add smoke assertions**

Append to `_smoke_diff.q` before the RESULT block (reuses `mkcols`/`mkrep` from Task 2):

```q
-1 "--- compare: table-level ---";
/ kindChange: declared partitioned, actual splayed
dk:mkrep[`t;`partitioned;`date] mkcols[enlist`a; enlist`long; enlist 0b; enlist`; enlist 0b];
ak:mkrep[`t;`splayed;`]          mkcols[enlist`a; enlist`long; enlist 0b; enlist`; enlist 0b];
rk:.qm.i.cmpTable[dk;ak];
chk["kindChange";     `kindChange in exec change from rk];
chk["kindChange sev"; `destructive in exec severity from rk where change=`kindChange];

/ partitionChange: date vs month
dp:mkrep[`t;`partitioned;`date]  mkcols[enlist`a; enlist`long; enlist 0b; enlist`; enlist 0b];
ap2:mkrep[`t;`partitioned;`month] mkcols[enlist`a; enlist`long; enlist 0b; enlist`; enlist 0b];
chk["partitionChange"; `partitionChange in exec change from .qm.i.cmpTable[dp;ap2]];

/ colOrderChange: same cols, different order
do:mkrep[`t;`splayed;`] mkcols[`a`b; `long`long; 00b; ``; 00b];
ao:mkrep[`t;`splayed;`] mkcols[`b`a; `long`long; 00b; ``; 00b];
chk["colOrderChange";     `colOrderChange in exec change from .qm.i.cmpTable[do;ao]];
chk["colOrderChange sev"; `change in exec severity from .qm.i.cmpTable[do;ao] where change=`colOrderChange];

-1 "--- compare: enum ---";
/ declared partitioned symbol (enum expected) vs on-disk not-enumerated
de:mkrep[`t;`partitioned;`date] mkcols[enlist`s; enlist`symbol; enlist 0b; enlist`; enlist 0b];
ae:mkrep[`t;`partitioned;`date] mkcols[enlist`s; enlist`symbol; enlist 0b; enlist`; enlist 0b];  / enum=0b on disk
chk["enumMismatch";     `enumMismatch in exec change from .qm.i.cmpEnum[de;ae]];
chk["enumMismatch sev"; `warning in exec severity from .qm.i.cmpEnum[de;ae] where change=`enumMismatch];
/ matching enum -> no row
am:mkrep[`t;`partitioned;`date] mkcols[enlist`s; enlist`symbol; enlist 0b; enlist`; enlist 1b];
chk["enum match -> none"; 0=count .qm.i.cmpEnum[de;am]];

-1 "--- compare: end-to-end pure ---";
chk["compare razes all"; 0<count .qm.i.compare[dk;ak]];
```

- [ ] **Step 4: Run**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: all prior + 10 new `ok` lines, `fail=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/diff.q _smoke_diff.q
git commit -m "feat(differ): kind/partition/order/enum comparison"
```

---

## Task 4: Options validation + severity rollup

**Files:**
- Modify: `src/diff.q`
- Modify: `_smoke_diff.q`

- [ ] **Step 1: Implement `i.normOpts` and `i.rollupWith`**

Insert into `src/diff.q` (inside `\d .qm`, after `i.compare`):

```q
/ validate + default the opts dict (spec section 6). only allowDestructive is recognised.
i.normOpts:{[opts]
  bad:key[opts] except enlist `allowDestructive;
  if[count bad; '"qm: unknown diff option(s): ",", " sv string bad];
  (enlist `allowDestructive)!enlist $[`allowDestructive in key opts; opts`allowDestructive; 0b] };

/ roll a rows table up into the result dict, given normalised opts
i.rollupWith:{[rows;o]
  ms:$[count rows; key[i.sevRank] max i.sevRank rows`severity; `ok];
  hasD:`destructive in rows`severity;
  ap:(not hasD) | o`allowDestructive;
  `maxSeverity`applyable`rows!(ms;ap;rows) };
```

- [ ] **Step 2: Add smoke assertions**

Append to `_smoke_diff.q`:

```q
-1 "--- rollup + opts ---";
o0:.qm.i.normOpts[()!()];
chk["normOpts default 0b"; o0[`allowDestructive]~0b];
chk["normOpts unknown throws"; thr[.qm.i.normOpts; (enlist`bogus)!enlist 1b]];

/ rows containing a destructive typeChange
rd:.qm.i.cmpCols[decl2;act2];               / from Task 2: has typeChange (destructive)
res0:.qm.i.rollupWith[rd; .qm.i.normOpts[()!()]];
chk["rollup maxSeverity destructive"; res0[`maxSeverity]~`destructive];
chk["rollup blocked by default";       res0[`applyable]~0b];
res1:.qm.i.rollupWith[rd; .qm.i.normOpts[(enlist`allowDestructive)!enlist 1b]];
chk["rollup applyable when allowed";   res1[`applyable]~1b];

/ change-only rows stay applyable
rch:.qm.i.cmpTable[do;ao];                  / colOrderChange only (change)
resc:.qm.i.rollupWith[rch; o0];
chk["rollup change maxSeverity"; resc[`maxSeverity]~`change];
chk["rollup change applyable";    resc[`applyable]~1b];
```

- [ ] **Step 3: Run**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: all prior + 8 new `ok` lines, `fail=0`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/diff.q _smoke_diff.q
git commit -m "feat(differ): opts validation and severity rollup"
```

---

## Task 5: On-disk introspection (`i.introspect`)

**Files:**
- Modify: `src/diff.q`
- Modify: `_smoke_diff.q`

This task touches disk. First a short discovery spike pins down the exact `meta` behavior, then the mapping is written against it.

- [ ] **Step 1: Add the temp-HDB fixture builder to `_smoke_diff.q`**

Append to `_smoke_diff.q` (before the RESULT block). This builds a throwaway HDB under `./testhdb`:

```q
-1 "--- build fixture HDB ./testhdb ---";
HDB:`:testhdb;
/ partitioned `quote over two dates: enumerated sym, a vector col, a string col, no attrs on disk
{[hdb;d]
  t:([] time:2#.z.p; sym:`A`B; bids:(1 2f;3 4f); note:("x";"yy"); px:1.0 2.0);
  (` sv hdb,(`$string d),`quote,`) set .Q.en[hdb;t];
 }[HDB] each 2025.01.01 2025.01.02;
/ splayed `ref: raw (non-enumerated) symbols, sorted attr on sym
(` sv HDB,`ref,`) set ([] sym:`s#`AA`BB; name:`x`y; active:01b);
chk["fixture quote exists"; not ()~key ` sv HDB,`2025.01.01`quote];
chk["fixture ref exists";   not ()~key ` sv HDB,`ref];
```

- [ ] **Step 2: Spike — print `meta` for both fixtures and confirm type-char conventions**

Add temporarily to `_smoke_diff.q` (you will remove this after reading the output):

```q
-1 "SPIKE quote meta:"; show 0!meta get ` sv HDB,`2025.01.01`quote;
-1 "SPIKE ref meta:";   show 0!meta get ` sv HDB,`ref;
```

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`

Confirm in the output (these are the kdb conventions the mapping below relies on):
- scalar columns show a **lowercase** type char (`p` timestamp, `f` float, `j` long, `s` symbol, `b` boolean);
- the vector column `bids` shows an **uppercase** `F` (uniform compound list ⇒ vector column);
- the string column `note` shows **uppercase** `C`;
- the enumerated `sym` (partitioned) shows `t`=`s` with `f`=`` `sym `` (foreign domain set); the splayed `ref.sym` shows `f`=`` ` `` (empty);
- `a` (attribute) shows `s` for `ref.sym`, empty otherwise.

If any convention differs (e.g. `bids` shows blank `" "` instead of `F`), adjust `i.colType` in Step 3 accordingly and note it. Then **delete the two SPIKE lines**.

- [ ] **Step 3: Implement type mapping, partition-field inference, dir reader, and `introspect`**

Insert into `src/diff.q` (inside `\d .qm`, after `i.rollupWith`):

```q
/ lowercase meta type char -> section-4 type symbol
i.charType:"bxhijefcspmdznuvtg"!`boolean`byte`short`int`long`real`float`char`symbol`timestamp`month`date`datetime`timespan`minute`second`time`guid;

/ meta type char -> (type symbol; list flag). uppercase => vector column; "C" => string.
i.colType:{[ch]
  if[ch="C"; :(`string;0b)];
  if[ch=" "; '"qm: unsupported on-disk column type (general/mixed list)"];
  lc:lower ch;
  if[not lc in key i.charType; '"qm: unknown on-disk type char '",ch,"'"];
  (i.charType lc; not ch=lc) };

/ infer the partition field name from partition dir-name format
i.partField:{[partDirs]
  s:string first partDirs;
  $[s like "[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]"; `date;
    s like "[0-9][0-9][0-9][0-9].[0-9][0-9]"; `month;
    s like "[0-9][0-9][0-9][0-9]"; `year;
    `int] };

/ read a splayed/partition table dir into an actual rep (section-6 + enum column)
i.readDir:{[dir;name;kind;pf]
  m:0!meta get dir;
  ct:i.colType each m`t;                       / list of (type;listFlag)
  colTab:flip `name`type`list`attr`default`defaultFn`enum!(
    m`c; ct[;0]; ct[;1]; m`a; count[m`c]#(::); count[m`c]#`; not null m`f);
  `name`kind`partitionField`columns!(name; kind; pf; colTab) };

/ introspect one on-disk table -> actual rep, or (::) if absent
i.introspect:{[root;table]
  / map the HDB's enum domain so enumerated symbol columns resolve to `s with f=`sym.
  / required when diffing an HDB the current session did not itself build.
  if[`sym in key root; `sym set get ` sv root,`sym];
  sdir:` sv root,table;
  if[`.d in key sdir; :i.readDir[sdir; table; `splayed; `]];   / splayed
  ents:key root;
  isPart:{[root;table;e] `.d in key ` sv root,e,table}[root;table] each ents;
  partDirs:ents where isPart;
  if[count partDirs;
     latest:last asc partDirs;
     :i.readDir[` sv root,latest,table; table; `partitioned; i.partField partDirs] ];
  (::) };
```

- [ ] **Step 4: Add introspection smoke assertions**

Append to `_smoke_diff.q`:

```q
-1 "--- introspect ---";
iq:.qm.i.introspect[HDB;`quote];
chk["introspect quote partitioned"; iq[`kind]~`partitioned];
chk["introspect quote pf=date";      iq[`partitionField]~`date];
chk["introspect bids is list";       1b~(.qm.i.colInfo[iq`columns;`bids])`list];
chk["introspect bids type float";    `float~(.qm.i.colInfo[iq`columns;`bids])`type];
chk["introspect note is string";     `string~(.qm.i.colInfo[iq`columns;`note])`type];
chk["introspect note not list";      0b~(.qm.i.colInfo[iq`columns;`note])`list];
chk["introspect sym enumerated";     1b~(.qm.i.colInfo[iq`columns;`sym])`enum];
ir:.qm.i.introspect[HDB;`ref];
chk["introspect ref splayed";        ir[`kind]~`splayed];
chk["introspect ref sym attr s";     `s~(.qm.i.colInfo[ir`columns;`sym])`attr];
chk["introspect ref sym raw (no enum)"; 0b~(.qm.i.colInfo[ir`columns;`sym])`enum];
chk["introspect absent -> ::";       (::)~.qm.i.introspect[HDB;`nope]];
```

- [ ] **Step 5: Run**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: all prior + fixture(2) + introspect(11) `ok` lines, `fail=0`, exit 0.
(If a fixture from a prior run lingers, prepend `rm -rf testhdb;` — see Task 8 run command.)

- [ ] **Step 6: Commit**

```bash
git add src/diff.q _smoke_diff.q
git commit -m "feat(differ): on-disk introspection via meta on mapped dirs"
```

---

## Task 6: `diffTable` (single table) + memory skip

**Files:**
- Modify: `src/diff.q`
- Modify: `_smoke_diff.q`

- [ ] **Step 1: Implement `i.tableRows` and `diffTable`**

Insert into `src/diff.q` (inside `\d .qm`, after `i.introspect`):

```q
/ rows for one declared table (memory -> skipped; else introspect + compare)
i.tableRows:{[root;declared]
  if[declared[`kind]=`memory;
     :i.row[declared`name;`;`skipped;::;::;"in-memory table; no disk target"]];
  i.compare[declared; i.introspect[root;declared`name]] };

/ public: diff one declared table against the HDB
diffTable:{[root;declared;opts]
  o:i.normOpts opts;
  if[not 11h=type key root; '"qm: hdb path not found or not a directory: ",string root];
  i.rollupWith[i.tableRows[root;declared]; o] };
```

- [ ] **Step 2: Add smoke assertions**

Append to `_smoke_diff.q`:

```q
-1 "--- diffTable ---";
/ declared quote matching disk except: declares attr `g on sym (disk has none) -> attrChange;
/ declares sym enum-by-default (partitioned) which matches disk enum -> no enumMismatch
dq:.qm.schema[`quote] (
  .qm.partitioned[`date];
  .qm.col [`time;  `timestamp];
  .qm.colx[`sym;   `symbol; `attr`g];
  .qm.colx[`bids;  `float;  `list`true];
  .qm.col [`note;  `string];
  .qm.col [`px;    `float] );
res:.qm.diffTable[HDB; dq; ()!()];
chk["diffTable result dict";  `maxSeverity`applyable`rows~key res];
chk["diffTable attrChange sym"; `attrChange in exec change from res[`rows] where column=`sym];
chk["diffTable no enumMismatch"; 0=count select from res[`rows] where change=`enumMismatch];
chk["diffTable applyable";      res[`applyable]~1b];

/ memory table -> skipped
dm:.qm.schema[`cfg] (.qm.memory[]; .qm.col[`k;`symbol]);
resm:.qm.diffTable[HDB; dm; ()!()];
chk["diffTable memory skipped"; `skipped in exec change from resm[`rows]];
chk["diffTable bad path throws"; thr[.qm.diffTable[`:does_not_exist;dq]; ()!()]];
```

- [ ] **Step 3: Run**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: all prior + 6 new `ok` lines, `fail=0`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/diff.q _smoke_diff.q
git commit -m "feat(differ): diffTable with memory skip and path check"
```

---

## Task 7: `diff` (whole HDB) + unmanaged-table detection

**Files:**
- Modify: `src/diff.q`
- Modify: `_smoke_diff.q`

- [ ] **Step 1: Implement `i.listTables` and `diff`**

Insert into `src/diff.q` (inside `\d .qm`, after `diffTable`):

```q
/ all table names present on disk (splayed at root + tables inside partition dirs)
i.listTables:{[root]
  ents:key root;
  isDir:{[root;e] 11h=type key ` sv root,e}[root] each ents;
  dirs:ents where isDir;
  splay:dirs where {[root;e] `.d in key ` sv root,e}[root] each dirs;
  partDirs:dirs where {[root;e] not `.d in key ` sv root,e}[root] each dirs;
  ptabs:$[count partDirs;
    distinct raze {[root;p]
      pe:key ` sv root,p;
      pe where {[root;p;t] `.d in key ` sv root,p,t}[root;p] each pe }[root] each partDirs;
    `symbol$()];
  distinct splay,ptabs };

/ public: diff a whole loadSchemas dict against the HDB
diff:{[root;declaredDict;opts]
  o:i.normOpts opts;
  if[not 11h=type key root; '"qm: hdb path not found or not a directory: ",string root];
  declRows:raze i.tableRows[root;] each value declaredDict;
  unmanaged:(i.listTables root) except key declaredDict;
  unmRows:raze {[nm] i.row[nm;`;`unmanagedTable;nm;::;"on disk, not declared"]} each unmanaged;
  i.rollupWith[declRows,unmRows; o] };
```

- [ ] **Step 2: Add smoke assertions**

Append to `_smoke_diff.q`:

```q
-1 "--- diff (whole HDB) ---";
/ declared dict: quote (matches w/ attrChange) + a brand-new table 'fills'. 'ref' on disk is undeclared.
dfills:.qm.schema[`fills] (.qm.splayed[]; .qm.col[`id;`long]);
decls:`quote`fills!(dq;dfills);
resa:.qm.diff[HDB; decls; ()!()];
chk["diff newTable fills";      `newTable in exec change from resa[`rows] where table=`fills];
chk["diff unmanaged ref";        `unmanagedTable in exec change from resa[`rows] where table=`ref];
chk["diff unmanaged is warning"; `warning in exec severity from resa[`rows] where change=`unmanagedTable];
chk["diff lists ref on disk";    `ref in .qm.i.listTables HDB];
chk["diff lists quote on disk";  `quote in .qm.i.listTables HDB];
chk["diff applyable (no destr)"; resa[`applyable]~1b];
```

- [ ] **Step 3: Run**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: all prior + 6 new `ok` lines, `fail=0`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/diff.q _smoke_diff.q
git commit -m "feat(differ): whole-HDB diff with unmanaged-table detection"
```

---

## Task 8: End-to-end destructive coverage + fixture cleanup

**Files:**
- Modify: `_smoke_diff.q`

- [ ] **Step 1: Add an end-to-end destructive scenario and the `allowDestructive` toggle**

Append to `_smoke_diff.q` (before the RESULT block):

```q
-1 "--- diff: destructive + opt-in ---";
/ declared quote that DROPS px, changes bids long->float already matches, changes note type -> destructive
dqd:.qm.schema[`quote] (
  .qm.partitioned[`date];
  .qm.col [`time; `timestamp];
  .qm.colx[`sym;  `symbol; `attr`g];
  .qm.colx[`bids; `float;  `list`true];
  .qm.col [`note; `symbol] );      / note is `string on disk -> typeChange (destructive); px dropped (destructive)
resd:.qm.diffTable[HDB; dqd; ()!()];
chk["e2e maxSeverity destructive"; resd[`maxSeverity]~`destructive];
chk["e2e blocked by default";       resd[`applyable]~0b];
chk["e2e dropColumn px";            `dropColumn in exec change from resd[`rows] where column=`px];
chk["e2e typeChange note";          `typeChange in exec change from resd[`rows] where column=`note];
resda:.qm.diffTable[HDB; dqd; (enlist`allowDestructive)!enlist 1b];
chk["e2e applyable when allowed";   resda[`applyable]~1b];
chk["e2e rows unchanged by opt";    count[resd`rows]=count resda`rows];
```

- [ ] **Step 2: Add fixture cleanup at the end of `_smoke_diff.q`**

Immediately before `exit fail`, add:

```q
/ remove the throwaway HDB so re-runs start clean
@[{system $[.z.o like "w*"; "rmdir /s /q testhdb"; "rm -rf testhdb"]};::;{}];
```

- [ ] **Step 3: Run (with a clean start)**

Run: `cd "C:/Users/Kenwjj/Documents/Git Repos/qmigrate"; rm -rf testhdb; QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: full suite, `fail=0`, exit 0, and `testhdb` removed afterward.

- [ ] **Step 4: Verify nothing leaked and run twice to confirm idempotency**

Run: `cd "C:/Users/Kenwjj/Documents/Git Repos/qmigrate"; QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q; QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: both runs `fail=0`, exit 0 (second run proves the build+cleanup is repeatable).

- [ ] **Step 5: Add `testhdb/` to `.gitignore`**

Add a line to `.gitignore`:

```
# differ smoke-test fixture HDB
testhdb/
```

- [ ] **Step 6: Commit**

```bash
git add _smoke_diff.q .gitignore
git commit -m "test(differ): end-to-end destructive coverage and fixture cleanup"
```

---

## Task 9: README + spec cross-reference

**Files:**
- Modify: `README.md`
- Modify: `src/diff.q` (header comment only, if needed)

- [ ] **Step 1: Add a Differ section to `README.md`**

Under the layout/usage area, add:

```markdown
## Differ

`src/diff.q` compares a declared schema against an on-disk HDB:

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

Design: `docs/superpowers/specs/2026-05-30-differ-design.md`.
```

Update the layout table to add `src/diff.q` and `_smoke_diff.q`.

- [ ] **Step 2: Run the full differ smoke once more as a final check**

Run: `cd "C:/Users/Kenwjj/Documents/Git Repos/qmigrate"; rm -rf testhdb; QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q`
Expected: `fail=0`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add README.md src/diff.q
git commit -m "docs: document the differ layer in README"
```

---

## Self-Review

**Spec coverage** (against `2026-05-30-differ-design.md`):
- Components (sec 2): `introspect` Task 5, `compare` Tasks 1-3, `diffTable` Task 6, `diff` Task 7. ✓
- Introspection via `meta` on mapped dir, latest partition, kind-from-layout, partition-field inference (sec 3): Task 5. ✓
- Change catalog + severities (sec 4): newTable T1; addColumn/dropColumn/typeChange/listChange/attrChange T2; kindChange/partitionChange/colOrderChange T3; enumMismatch T3; unmanagedTable T7; skipped T6. ✓
- Result rep `maxSeverity`/`applyable`/`rows` (sec 5): Task 4. ✓
- opts + reject-unknown (sec 6): Task 4. ✓
- Edge cases (sec 7): bad path T6; memory skip T6; absent table -> newTable T1; unmanaged T7. ✓
- Testing via hand-rolled harness + temp HDB (sec 8): Tasks 5-8. ✓

**Placeholder scan:** No TBD/TODO; every code step is complete q. The only deliberately-empty stubs (`i.cmpCols`/`i.cmpTable`/`i.cmpEnum` in Task 1) are filled in Tasks 2-3 and are explicitly described as stubs.

**Type/name consistency:** `i.row`, `i.noRows`, `i.colInfo`, `i.cmpCols`, `i.cmpTable`, `i.cmpEnum`, `i.compare`, `i.normOpts`, `i.rollupWith`, `i.charType`, `i.colType`, `i.partField`, `i.readDir`, `i.introspect`, `i.tableRows`, `i.listTables`, `diffTable`, `diff` — names used consistently across tasks. Result keys `maxSeverity`/`applyable`/`rows` and row columns `table`/`column`/`change`/`from`/`to`/`severity`/`detail` consistent throughout.

**Known empirical risk:** the `meta` type-char conventions (uppercase ⇒ vector, `"C"` ⇒ string, enum `f`) are confirmed by the Task 5 Step 2 spike before the mapping is relied on; the temp-HDB fixture exercises every shape end-to-end.
```
