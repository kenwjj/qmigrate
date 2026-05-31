# Apply Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `.qm.apply`, the layer that executes a plan result against an on-disk HDB with a backup-then-mutate + rollback safety model.

**Architecture:** A new `src/apply.q` in namespace `.qm`, loaded after `src/plan.q`. A read-only **preflight** (validate, resolve `defaultFn`, compute the backup/create sets) feeds an **execute** phase (back up, run handlers in `seq` order, fan out per partition) with **rollback** on any failure. Seven op handlers dispatch from `i.runOp`; per-op file targets from `i.opTargets`. The only layer that writes to disk.

**Tech Stack:** kdb+/q (KDB-X 5.0). Reuses the DSL (`.qm.schema`/`.qm.col`/`.qm.colx`), the differ (`.qm.diff`), and the plan layer (`.qm.plan`) to build faithful end-to-end inputs. Tests live in a new hand-rolled `_smoke_apply.q` harness.

---

## Background the engineer needs

**Spec:** `docs/superpowers/specs/2026-05-31-apply-layer-design.md`. Read it. Sections 5 (handlers), 6 (backup/rollback + sentinel), and 7 (preflight throws) are the heart of this work.

**Every code block below was prototyped and run green against KDB-X 5.0** before this plan was written (30 end-to-end checks across all 7 handlers, gate/noop/dryRun/rollback, and both preflight throws). Transcribe it faithfully.

**What a plan result looks like** (output of `.qm.plan`, defined in `src/plan.q`):

```q
`maxSeverity`applyable`ops ! (`change; 1b; <ops table>)
```

The `ops` table has columns `seq table column op change severity detail params`, one row per operation, ordered by `seq`. `op` is one of `createTable addColumn dropColumn setAttr clearAttr reorderColumns reEnumerate manual`. `params` is a dict cell carrying the op payload:

- `createTable` → `` `kind`partitionField`columns ``
- `addColumn` → a declared-column dict `` `type`list`attr`default`defaultFn `` (call it `ci`)
- `setAttr` → `` (enlist`attr)!enlist <attr sym> ``; `clearAttr` → `` (enlist`from)!enlist <old attr> ``
- `reorderColumns` → `` (enlist`order)!enlist <declared column-name list> ``
- `reEnumerate` → `` (enlist`enumerate)!enlist 1b ``
- `dropColumn` / `manual` → `()!()`

**On-disk layout reminders** (mirrors `src/diff.q` introspection):
- A **splayed** table is a directory `root/<table>/` containing one file per column plus a `.d` file (a symbol list giving column order). Read it with `get`.
- A **partitioned** table has a `root/<partition>/<table>/` directory per partition (e.g. `root/2026.05.30/trade/`), each splayed the same way. The partition column is **virtual** — derived from the directory name, never stored as a column file.
- The root `sym` file holds the enumeration domain. Partitioned symbol columns are enumerated against it (schema-spec §9); splayed symbol columns are raw.

**q reminders for this work (each verified):**
- `set` **auto-creates parent directories**. `(`:a/b/c) set 1 2 3` creates `a/b`. No `mkdir` needed in `src/apply.q`.
- `fills` and `cols` are **reserved q keywords** — never use them as local variable names (you get an `assign` error). This plan uses `fillv` and `colz`. (`type`, `attr`, `name` are also reserved; only ever use them as *dict keys* / *indices*, never as locals — this code does.)
- Protected **dyadic** apply is `.[f;(arg1;arg2);errFn]` — NOT `@[...]`, which applies monadically and throws a valence error.
- Enum-extend: `?[`sym;v]` enumerates `v` against the global variable `sym`, **appending** unseen values, and returns the enum vector. Load `sym` from disk into the global first, persist it after.
- Apply an attribute on disk by read-modify-write: `p set `p#get p` (or `` `s#``/`` `u#``/`` `g#``). Clear with `p set `#get p`.
- `hdel` removes a file, or an **empty** directory. To remove a created tree, delete files first, then dirs (deepest-first).
- `each` over a table yields one **row dict** per iteration; `r\`op` indexes a field.
- Build single-entry declared dicts as `(enlist`t)!enlist schema`, never `` `t!schema `` (the latter is a keyed table in KDB-X).

**How to run the harness** (from the repo root):

```
QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q
```

The harness exits non-zero on any failed check and prints `RESULT  ok=N fail=M` last. **Treat `fail=0` as the pass signal**; the cumulative `ok=N` counts below are guides — if a count is off by a few but `fail=0`, proceed.

---

## File Structure

- **Create `src/apply.q`** — the whole apply layer in `.qm`, loaded after `diff.q`/`plan.q`. One responsibility: execute a plan result against the HDB with backup/rollback. ~15 small internal helpers + the public `.qm.apply`.
- **Create `_smoke_apply.q`** — hand-rolled harness. Builds throwaway HDBs under `testhdb_*/`, removed on exit. Mirrors `_smoke_diff.q`/`_smoke_plan.q` style (`chk`/`thr`/`rmrf`, `exit fail`).
- **Modify `README.md`** — document the apply layer; add `src/apply.q` / `_smoke_apply.q` to Layout and Testing; bump the status line.

---

## Task 1: Scaffold `src/apply.q` (low-level helpers) and the harness

**Files:**
- Create: `src/apply.q`
- Create: `_smoke_apply.q`

- [ ] **Step 1: Create the harness with helper unit-tests**

Create `_smoke_apply.q`:

```q
/ Manual smoke check for the .qm apply layer (not a test framework — see memory).
/ Run: QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q
\l src/qm.q
\l src/diff.q
\l src/plan.q
\l src/apply.q

ok:0; fail:0;
chk:{[d;c] $[c;[ok+:1;-1"  ok   ",d];[fail+:1;-1"  FAIL ",d]]};
thr:{[f;a] 1b~@[f;a;{[e]1b}]};
rmrf:{[d] @[{system $[.z.o like "w*";"rmdir /s /q ",ssr[d;"/";"\\"];"rm -rf ",d]};::;{}]};

-1"--- apply: low-level helpers ---";
rmrf "testhdb_apply"; R:`:testhdb_apply; sd:` sv R,`inst;
(` sv sd,`sym) set `AA`BB`CC;
(` sv sd,`px)  set 1 2 3f;
(` sv sd,`.d)  set `sym`px;
chk["getD";            (.qm.i.getD sd)~`sym`px];
chk["rowCount=3";      3=.qm.i.rowCount sd];
chk["kindOf splayed";  `splayed~.qm.i.kindOf[R;`inst]];
chk["kindOf absent";   `absent~.qm.i.kindOf[R;`nope]];
chk["partDirs splayed";(.qm.i.partDirs[R;`inst])~enlist sd];
chk["attrOK s sorted"; .qm.i.attrOK[`s; 1 2 3]];
chk["attrOK u dups";   not .qm.i.attrOK[`u; 1 1 2]];
chk["attrOK empty";    .qm.i.attrOK[`; 3 1 2]];
chk["enum extends";    `AA`DD~get[` sv R,`sym] .qm.i.enum[R;`AA`DD]];
chk["tnull long";      (.qm.i.tnull`long)~enlist 0N];
chk["sentinelDir date";"1900.01.01"~.qm.i.sentinelDir`date];
chk["sentinelDir int"; "0"~.qm.i.sentinelDir`int];
rmrf "testhdb_apply";

-1"";
-1"RESULT  ok=",string[ok]," fail=",string fail;
exit fail
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: error loading `src/apply.q` (file does not exist), or `.qm.i.getD` undefined.

- [ ] **Step 3: Create `src/apply.q` with the low-level helpers**

Create `src/apply.q`:

```q
/ qmigrate — apply layer (Phase 1)
/ Spec: docs/superpowers/specs/2026-05-31-apply-layer-design.md
//
/ Executes a plan result (.qm.plan output) against the on-disk HDB, with a
/ backup-then-mutate + rollback safety model. The only layer that writes.
/ Public (writes): .qm.apply
/ Read-only core:  .qm.i.preflight   Handlers: .qm.i.runOp / .qm.i.opTargets

\d .qm

/ ---------------------------------------------------------------------------
/ low-level disk helpers (path symbols are `:...; q `set` auto-creates dirs)
/ ---------------------------------------------------------------------------
i.dpath:{[dir;c] ` sv dir,c};                          / `:dir/col
i.getD :{[dir] get i.dpath[dir;`.d]};                  / on-disk column-name list
i.rowCount:{[dir] d:i.getD dir; $[0=count d;0;count get i.dpath[dir;first d]]};

/ on-disk table kind by layout (mirrors diff introspection); `absent if neither
i.kindOf:{[root;tbl]
  if[`.d in key ` sv root,tbl; :`splayed];
  ents:key root;
  if[count ents where {[root;tbl;e](not e~`.qmbackup)&`.d in key ` sv root,e,tbl}[root;tbl]each ents; :`partitioned];
  `absent };

/ physical dirs an existing table fans out to (splayed -> 1; partitioned -> all partitions, sorted)
i.partDirs:{[root;tbl]
  if[`.d in key ` sv root,tbl; :enlist ` sv root,tbl];
  ents:key root;
  parts:asc ents where {[root;tbl;e](not e~`.qmbackup)&`.d in key ` sv root,e,tbl}[root;tbl]each ents;
  {[root;tbl;p] ` sv root,p,tbl}[root;tbl]each parts };

/ enumerate vector v against the root sym file, EXTENDING + persisting it; returns enum vec
i.enum:{[root;v]
  symp:` sv root,`sym;
  `sym set $[`sym in key root; get symp; `$()];
  e:?[`sym;v]; symp set get `sym; e };

/ attr-satisfiability: does applying attr `a` to vector v succeed? (` => no attr => ok)
i.attrOK:{[a;v] $[a~`;1b; 1b~.[{[a;v]a#v;1b};(a;v);{[e]0b}]]};

/ typed-null 1-vector per declared type symbol (sample cells for createTable)
i.tnull:`boolean`byte`short`int`long`real`float`char`symbol`timestamp`month`date`datetime`timespan`minute`second`time`guid`string!(
  enlist 0b;enlist 0x00;enlist 0Nh;enlist 0Ni;enlist 0N;enlist 0Ne;enlist 0Nf;enlist " ";
  enlist `;enlist 0Np;enlist 0Nm;enlist 0Nd;enlist 0Nz;enlist 0Nn;enlist 0Nu;enlist 0Nv;enlist 0Nt;enlist 0Ng;enlist "");

/ sentinel partition dir-name for an empty created partitioned table (by field-name convention)
i.sentinelDir:{[pf] $[pf~`date;"1900.01.01"; pf~`month;"1900.01"; pf~`year;"1900"; "0"]};

\d .
```

- [ ] **Step 4: Run the harness to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=12 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): scaffold apply layer with low-level disk helpers"
```

---

## Task 2: Backup / restore / delete-created

**Files:**
- Modify: `src/apply.q`
- Modify: `_smoke_apply.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_apply.q`, immediately before the final `-1"";` block:

```q
-1"--- apply: backup / restore / delete-created ---";
rmrf "testhdb_bk"; B:`:testhdb_bk; bd:` sv B,`t;
(` sv bd,`a) set 1 2 3;
(` sv bd,`.d) set enlist `a;
bdir:.qm.i.backupDir[B; ()!()];
chk["backupDir default"; bdir~` sv B,`.qmbackup];
oa:` sv bd,`a;
.qm.i.doBackup[bdir; enlist oa];
oa set 9 9 9;                                  / mutate
.qm.i.restore[bdir; enlist oa];
chk["restore round-trip"; (get oa)~1 2 3];
/ create + delete a nested tree, deepest-first
nf:` sv B,`p,`t,`x;
nf set 1 2;
.qm.i.deleteCreated (nf; ` sv B,`p,`t; ` sv B,`p);
chk["deleteCreated removed file"; not `x in key ` sv B,`p,`t];
chk["deleteCreated removed dirs"; not `p in key B];
rmrf "testhdb_bk";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: `.qm.i.backupDir` undefined → the new checks FAIL.

- [ ] **Step 3: Add the backup helpers**

In `src/apply.q`, immediately before the closing `\d .`, add:

```q
/ ---------------------------------------------------------------------------
/ backup sidecar (flatten each backed-up path to one flat name under the dir)
/ ---------------------------------------------------------------------------
i.backupDir:{[root;opts] $[`backupDir in key opts; opts`backupDir; ` sv root,`.qmbackup]};
i.bkey:{[bdir;p] ` sv bdir,`$ssr[1_string p;"/";"_"]};
i.symExists:{[root] `sym in key root};

i.doBackup:{[bdir;bpaths] {[bdir;p] (i.bkey[bdir;p]) set get p}[bdir] each bpaths;};
i.restore :{[bdir;bpaths] {[bdir;p] p set get i.bkey[bdir;p]}[bdir] each bpaths;};
i.deleteCreated:{[cpaths]
  / deepest-first by slash count, so files go before their dirs
  ord:idesc {sum "/"=x} each 1_'string cpaths;
  {hdel x} each cpaths ord; };
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=16 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): backup/restore/delete-created sidecar helpers"
```

---

## Task 3: The spine — preflight, execute, report, apply (+ setAttr handler)

This is the largest task: it builds the read-only `i.preflight`, the `i.execute` loop with rollback, the `i.report` builder, the public `.qm.apply` (gate / noop / dryRun / execute), `i.normApplyOpts`, `i.fillFor`, `i.entry`, and the `i.opTargets` / `i.runOp` dispatchers seeded with the **`setAttr`** branch. Later tasks add one handler branch each.

> **Note (name collision):** `diff.q` already defines `.qm.i.normOpts`. Apply's option-normaliser must use a **different** name — `i.normApplyOpts` — or it clobbers the differ's `normOpts` when both files are loaded, breaking `allowDestructive` handling. The code below uses `i.normApplyOpts`.

**Files:**
- Modify: `src/apply.q`
- Modify: `_smoke_apply.q`

- [ ] **Step 1: Write the failing test** (gate, noop, dryRun, and setAttr end-to-end)

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: gate / noop / dryRun / setAttr e2e ---";
rmrf "testhdb_s"; S:`:testhdb_s; ssd:` sv S,`inst;
(` sv ssd,`sym)  set `AA`BB`CC;            / already sorted -> `s satisfiable
(` sv ssd,`name) set `x`y`z;
(` sv ssd,`.d)   set `sym`name;
/ declared: set `s on sym (setAttr), everything else matches
dinst:.qm.schema[`inst] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`s]; .qm.col[`name;`symbol]);
dr:.qm.diff[S; (enlist`inst)!enlist dinst; ()!()];
pl:.qm.plan[dr; (enlist`inst)!enlist dinst];
/ dryRun first: no writes
resDry:.qm.apply[S; pl; (enlist`dryRun)!enlist 1b];
chk["dryRun status";   resDry[`status]~`dryRun];
chk["dryRun planned";  `planned in resDry[`ops]`status];
chk["dryRun no attr";  `~attr get ` sv ssd,`sym];
/ real apply
res:.qm.apply[S; pl; ()!()];
chk["setAttr applied";  res[`status]~`applied];
chk["sym has s attr";   `s=attr get ` sv ssd,`sym];
chk["report has done";  `done in res[`ops]`status];
/ noop: re-apply same plan against the now-matching HDB
dr2:.qm.diff[S; (enlist`inst)!enlist dinst; ()!()];
pl2:.qm.plan[dr2; (enlist`inst)!enlist dinst];
res2:.qm.apply[S; pl2; ()!()];
chk["noop status"; res2[`status]~`noop];
/ gate: a destructive plan is blocked
ddrp:.qm.schema[`inst] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`s]);   / drops `name
plD:.qm.plan[.qm.diff[S;(enlist`inst)!enlist ddrp;()!()]; (enlist`inst)!enlist ddrp];
resB:.qm.apply[S; plD; ()!()];
chk["blocked status";   resB[`status]~`blocked];
chk["blocked no write"; `name in get ` sv ssd,`.d];
chk["bad opts throws";  thr[.qm.apply[S;pl;]; (enlist`bogus)!enlist 1]];
chk["malformed plan throws"; thr[.qm.apply[S; (enlist`bogus)!enlist 1;]; ()!()]];
rmrf "testhdb_s";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: `.qm.apply` undefined → the new checks FAIL.

- [ ] **Step 3: Add the spine** (insert before the closing `\d .`, after the backup helpers)

```q
/ ---------------------------------------------------------------------------
/ options
/ ---------------------------------------------------------------------------
i.normApplyOpts:{[opts]
  if[not 99h=type opts; '"qm: apply: opts must be a dict"];
  bad:key[opts] except `dryRun`backupDir;
  if[count bad; '"qm: apply: unknown option(s): ",", " sv string bad];
  opts };

/ ---------------------------------------------------------------------------
/ per-dir resolved fill for addColumn (raw symbols, pre-enumeration)
/ ---------------------------------------------------------------------------
i.fillFor:{[dir;ci]
  n:i.rowCount dir;
  $[not ci[`defaultFn]~`;
      [f:@[get;ci`defaultFn;{[s;e]'"qm: apply: defaultFn not defined: ",string s}[ci`defaultFn]];
       v:f[dir;`col]; if[not n=count v; '"qm: apply: defaultFn returned wrong length"]; v];
    not ci[`default]~(::);
      $[ci`list; n#enlist ci`default; n#ci`default];
    / neither default nor defaultFn -> typed null (scalar) / empty typed list (list col)
    $[ci`list; n#enlist 0#first i.tnull ci`type; n#first i.tnull ci`type] ] };

/ ---------------------------------------------------------------------------
/ build + validate one entry from a plan op row (READ-ONLY; throws on bad input)
/ ---------------------------------------------------------------------------
i.entry:{[root;r]
  op:r`op; tbl:r`table; col:r`column;
  base:`op`seq`table`column`severity`detail`params!(op;r`seq;tbl;col;r`severity;r`detail;r`params);
  $[op~`createTable;
      base,`kind`pf`colz`dirs`isPart`fillv!(r[`params]`kind;r[`params]`partitionField;r[`params]`columns;();(r[`params]`kind)~`partitioned;()!());
    op in `addColumn`dropColumn`setAttr`clearAttr`reorderColumns`reEnumerate;
      [dirs:i.partDirs[root;tbl]; isPart:`partitioned~i.kindOf[root;tbl];
       fillv:$[op~`addColumn; dirs!i.fillFor[;r`params] each dirs; ()!()];
       / validation (fail before touching data)
       if[op~`addColumn; {[a;v] if[not i.attrOK[a;v]; '"qm: apply: new column data does not satisfy attr"]}[r[`params]`attr;] each value fillv];
       if[op~`setAttr;   {[d;col;a] if[not i.attrOK[a;get i.dpath[d;col]]; '"qm: apply: on-disk data does not satisfy attr ",string a]}[;col;r[`params]`attr] each dirs];
       base,`dirs`isPart`fillv!(dirs;isPart;fillv)];
    base ] };   / manual etc — kept for the report, never run

/ ---------------------------------------------------------------------------
/ per-op FILE TARGETS (pure) -> `backup`create!(backupPaths;createPaths)
/ ---------------------------------------------------------------------------
i.opTargets:{[root;e]
  op:e`op; tbl:e`table; col:e`column; dirs:e`dirs;
  symp:` sv root,`sym;
  symBC:$[i.symExists root; (enlist symp;()); ((); enlist symp)];   / sym: (backup; create)
  $[op in `setAttr`clearAttr;
      `backup`create!(i.dpath[;col] each dirs; ());
    `backup`create!(();()) ] };

/ ---------------------------------------------------------------------------
/ per-op RUN (writes). Each branch fans out across e`dirs.
/ ---------------------------------------------------------------------------
i.runOp:{[root;e]
  op:e`op; tbl:e`table; col:e`column; dirs:e`dirs;
  $[op~`setAttr;
      {[col;a;dir] p:i.dpath[dir;col]; p set a#get p}[col;e[`params]`attr] each dirs;
    '"qm: apply: unknown op ",string op ] };

/ ---------------------------------------------------------------------------
/ preflight (READ-ONLY): build entries, aggregate backup/create sets
/ ---------------------------------------------------------------------------
i.preflight:{[root;planResult;opts]
  if[not all `applyable`ops in key planResult; '"qm: apply: malformed plan result"];
  ops:planResult`ops;
  exrows:select from ops where not op=`manual;
  entries:i.entry[root;] each exrows;          / validates; may throw
  tgts:i.opTargets[root;] each entries;
  `entries`backup`create!(entries; raze tgts@\:`backup; raze tgts@\:`create) };

/ ---------------------------------------------------------------------------
/ execute: back up -> run in seq order -> rollback (restore + delete) on fail
/ ---------------------------------------------------------------------------
i.execute:{[root;wl;opts]
  bdir:i.backupDir[root;opts];
  es:wl`entries;
  i.doBackup[bdir; distinct wl`backup];
  failIdx:0N; i:0; n:count es;
  while[(i<n)&null failIdx;
    runok:1b~.[{[root;e] i.runOp[root;e]; 1b};(root;es i);{[e]0b}];
    $[runok; i+:1; failIdx:i] ];
  $[null failIdx;
    `status`failIdx`backup!(`applied; 0N; bdir);
    [i.restore[bdir; distinct wl`backup]; i.deleteCreated wl`create;
     `status`failIdx`backup!(`rolledBack; failIdx; bdir)] ] };

/ ---------------------------------------------------------------------------
/ report: full plan ops + a status column keyed by seq
/ ---------------------------------------------------------------------------
i.report:{[ops;statusBySeq]
  flip `seq`table`column`op`severity`status`detail!(
    ops`seq; ops`table; ops`column; ops`op; ops`severity;
    statusBySeq ops`seq; ops`detail) };

/ ---------------------------------------------------------------------------
/ public: execute a plan result against the HDB
/ ---------------------------------------------------------------------------
apply:{[root;planResult;opts]
  if[not 11h=type key root; '"qm: apply: hdb path not found: ",string root];
  o:i.normApplyOpts opts;
  if[not all `applyable`ops in key planResult; '"qm: apply: malformed plan result"];
  ops:planResult`ops;
  / gate: refuse a non-applyable plan
  if[not planResult`applyable;
     :`status`ops`backup!(`blocked; i.report[ops; (exec seq from ops)!count[ops]#`skipped]; `)];
  exrows:select from ops where not op=`manual;
  if[0=count exrows;
     :`status`ops`backup!(`noop; i.report[ops; (exec seq from ops)!count[ops]#`skipped]; `)];
  wl:i.preflight[root;planResult;o];
  if[$[`dryRun in key o; o`dryRun; 0b];
     sd:(exec seq from ops)!count[ops]#`skipped;
     sd[exrows`seq]:`planned;
     :`status`ops`backup!(`dryRun; i.report[ops;sd]; `)];
  r:i.execute[root;wl;o];
  exseq:exrows`seq;
  sd:(exec seq from ops)!count[ops]#`skipped;
  $[r[`status]~`applied;
     sd[exseq]:`done;
     [sd[exseq]:`rolledBack; sd[exseq r`failIdx]:`failed] ];
  `status`ops`backup!(r`status; i.report[ops;sd]; r`backup) };
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=27 fail=0`. (Downstream task counts in this plan are guides; the real running total after this task is 27 — trust `fail=0`.)

- [ ] **Step 5: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): preflight/execute/rollback spine + setAttr handler"
```

---

## Task 4: `addColumn` handler (literal default, list default, typed-null)

`i.entry` already resolves and validates the addColumn fill (Task 3). This task adds the `addColumn` branches to `i.opTargets` and `i.runOp`.

**Files:**
- Modify: `src/apply.q` (`i.opTargets`, `i.runOp`)
- Modify: `_smoke_apply.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: addColumn (literal / list / typed-null) ---";
rmrf "testhdb_ac"; AC:`:testhdb_ac; acd:` sv AC,`t;
(` sv acd,`k) set 1 2 3;
(` sv acd,`.d) set enlist `k;
dac:.qm.schema[`t] (
  .qm.splayed[];
  .qm.col [`k;     `long];
  .qm.colx[`flag;  `boolean; (enlist`default)!enlist 1b];   / literal default
  .qm.colx[`tags;  `symbol;  `default`list!(enlist`x;1b)];   / list col, list-valued default per cell
  .qm.col [`note;  `symbol] );                                / no default -> typed null
plac:.qm.plan[.qm.diff[AC;(enlist`t)!enlist dac;()!()]; (enlist`t)!enlist dac];
resac:.qm.apply[AC; plac; ()!()];
chk["addColumn applied";   resac[`status]~`applied];
chk["literal default";     (get ` sv acd,`flag)~3#1b];
chk["list default cell";   (get ` sv acd,`tags)~3#enlist enlist `x];
chk["typed-null default";  (get ` sv acd,`note)~3#`];
chk["all in .d";           (get ` sv acd,`.d)~`k`flag`tags`note];
chk["re-diff ok";          `ok~(.qm.diff[AC;(enlist`t)!enlist dac;()!()])`maxSeverity];
rmrf "testhdb_ac";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: addColumn checks FAIL — `i.runOp` hits the `unknown op` throw, so `execute` rolls back and `status` is `rolledBack`, not `applied`.

- [ ] **Step 3: Add the `addColumn` branch to `i.opTargets`**

In `src/apply.q`, in `i.opTargets`, insert this branch immediately before the `op in \`setAttr\`clearAttr;` branch:

```q
    op~`addColumn;
      [b:i.dpath[;`.d] each dirs; c:i.dpath[;col] each dirs;
       if[e`isPart; if[(e[`params]`type)~`symbol; b,:symBC 0; c,:symBC 1]];
       `backup`create!(b;c)];
```

- [ ] **Step 4: Add the `addColumn` branch to `i.runOp`**

In `i.runOp`, insert this branch immediately before the `op~\`setAttr;` branch:

```q
    op~`addColumn;
      {[root;e;dir]
        ci:e`params; v:e[`fillv]dir;
        v:$[e[`isPart]&(ci`type)~`symbol; i.enum[root;v]; v];   / enumerate if partitioned symbol
        v:$[(ci`attr)~`; v; (ci`attr)#v];                        / apply declared attr
        (i.dpath[dir;e`column]) set v;
        (i.dpath[dir;`.d]) set (i.getD dir),e`column }[root;e] each dirs;
```

- [ ] **Step 5: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=34 fail=0`.

- [ ] **Step 6: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): addColumn handler (literal/list/typed-null defaults)"
```

---

## Task 5: `addColumn` computed default (`defaultFn`) + preflight throws

The `defaultFn` path in `i.fillFor` and the attr validation in `i.entry` were written in Task 3; this task proves them end-to-end and proves the fail-before-touching-data guarantee (spec §7): a missing `defaultFn` and an unsatisfiable attribute each throw, leaving the HDB untouched.

**Files:**
- Modify: `_smoke_apply.q` (assertions only)

- [ ] **Step 1: Write the test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: addColumn defaultFn + preflight throws ---";
rmrf "testhdb_fn"; FN:`:testhdb_fn; fnd:` sv FN,`t;
(` sv fnd,`a) set 10 20 30;
(` sv fnd,`.d) set enlist `a;
.user.mk:{[path;col] count[get ` sv path,`a]#42};      / returns a length-n long vector
dfn:.qm.schema[`t] (.qm.splayed[]; .qm.col[`a;`long]; .qm.colx[`b;`long;`defaultFn`.user.mk]);
plfn:.qm.plan[.qm.diff[FN;(enlist`t)!enlist dfn;()!()]; (enlist`t)!enlist dfn];
resfn:.qm.apply[FN; plfn; ()!()];
chk["defaultFn applied"; resfn[`status]~`applied];
chk["defaultFn values";  (get ` sv fnd,`b)~3#42];
/ missing defaultFn -> preflight throws, nothing created.
/ use a FRESH HDB (only col a) so the plan is applyable (no destructive drop of `b);
/ reusing FN would diff `b on disk vs undeclared -> dropColumn -> blocked before preflight.
rmrf "testhdb_bad"; FNB:`:testhdb_bad; fnbd:` sv FNB,`t;
(` sv fnbd,`a) set 10 20 30;
(` sv fnbd,`.d) set enlist `a;
dbad:.qm.schema[`t] (.qm.splayed[]; .qm.col[`a;`long]; .qm.colx[`c;`long;`defaultFn`.user.nope]);
plbad:.qm.plan[.qm.diff[FNB;(enlist`t)!enlist dbad;()!()]; (enlist`t)!enlist dbad];
chk["missing defaultFn throws"; thr[.qm.apply[FNB;plbad;]; ()!()]];
chk["throw left no col c";      not `c in get ` sv fnbd,`.d];
rmrf "testhdb_bad";
rmrf "testhdb_fn";
/ unsatisfiable attribute -> preflight throws, nothing marked
rmrf "testhdb_at"; AT:`:testhdb_at; atd:` sv AT,`t;
(` sv atd,`u) set 1 1 2;                               / dups -> cannot be `u
(` sv atd,`.d) set enlist `u;
dat:.qm.schema[`t] (.qm.splayed[]; .qm.colx[`u;`long;`attr`u]);    / declared `u -> setAttr
plat:.qm.plan[.qm.diff[AT;(enlist`t)!enlist dat;()!()]; (enlist`t)!enlist dat];
chk["unsatisfiable attr throws"; thr[.qm.apply[AT;plat;]; ()!()]];
chk["attr-throw left col unmarked"; `~attr get ` sv atd,`u];
rmrf "testhdb_at";
```

- [ ] **Step 2: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=40 fail=0`. (Behaviour already implemented; this verifies it. If `missing defaultFn throws` fails, confirm `i.fillFor`'s `@[get;...]` error branch is intact; if `unsatisfiable attr throws` fails, confirm `i.entry`'s setAttr validation line.)

- [ ] **Step 3: Commit**

```
git add _smoke_apply.q
git commit -m "test(apply): addColumn defaultFn + missing-fn/unsatisfiable-attr throws"
```

---

## Task 6: `dropColumn` handler (destructive)

**Files:**
- Modify: `src/apply.q` (`i.opTargets`, `i.runOp`)
- Modify: `_smoke_apply.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: dropColumn (destructive, allowDestructive) ---";
rmrf "testhdb_dc"; DC:`:testhdb_dc; dcd:` sv DC,`t;
(` sv dcd,`keep) set 1 2 3;
(` sv dcd,`gone) set `a`b`c;
(` sv dcd,`.d)   set `keep`gone;
ddc:.qm.schema[`t] (.qm.splayed[]; .qm.col[`keep;`long]);     / `gone not declared -> drop
/ destructive: must opt in at the differ for the plan to be applyable
pldc:.qm.plan[.qm.diff[DC;(enlist`t)!enlist ddc;(enlist`allowDestructive)!enlist 1b]; (enlist`t)!enlist ddc];
resdc:.qm.apply[DC; pldc; ()!()];
chk["dropColumn applied"; resdc[`status]~`applied];
chk["gone removed from .d"; (get ` sv dcd,`.d)~enlist `keep];
chk["gone file deleted";    not `gone in key dcd];
chk["re-diff ok";           `ok~(.qm.diff[DC;(enlist`t)!enlist ddc;()!()])`maxSeverity];
rmrf "testhdb_dc";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: dropColumn checks FAIL (`unknown op` → rollback).

- [ ] **Step 3: Add the `dropColumn` branch to `i.opTargets`**

Insert before the `op in \`setAttr\`clearAttr;` branch:

```q
    op~`dropColumn;
      `backup`create!((i.dpath[;col] each dirs),i.dpath[;`.d] each dirs; ());
```

- [ ] **Step 4: Add the `dropColumn` branch to `i.runOp`**

Insert before the `op~\`setAttr;` branch:

```q
    op~`dropColumn;
      {[col;dir] hdel i.dpath[dir;col]; (i.dpath[dir;`.d]) set (i.getD dir)except col}[col] each dirs;
```

- [ ] **Step 5: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=44 fail=0`.

- [ ] **Step 6: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): dropColumn handler (destructive)"
```

---

## Task 7: `clearAttr` handler

**Files:**
- Modify: `src/apply.q` (`i.runOp`)
- Modify: `_smoke_apply.q`

`clearAttr` shares the `opTargets` branch with `setAttr` (already present: `op in \`setAttr\`clearAttr`). Only `i.runOp` needs the new branch.

- [ ] **Step 1: Write the failing test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: clearAttr ---";
rmrf "testhdb_ca"; CA:`:testhdb_ca; cad:` sv CA,`t;
(` sv cad,`g) set `g#`a`b`c;                  / on-disk has `g attr
(` sv cad,`.d) set enlist `g;
dca:.qm.schema[`t] (.qm.splayed[]; .qm.col[`g;`symbol]);    / declared: no attr -> clearAttr
plca:.qm.plan[.qm.diff[CA;(enlist`t)!enlist dca;()!()]; (enlist`t)!enlist dca];
resca:.qm.apply[CA; plca; ()!()];
chk["clearAttr applied"; resca[`status]~`applied];
chk["attr cleared";      `~attr get ` sv cad,`g];
rmrf "testhdb_ca";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: clearAttr checks FAIL (`unknown op` → rollback).

- [ ] **Step 3: Add the `clearAttr` branch to `i.runOp`**

Insert before the `op~\`setAttr;` branch:

```q
    op~`clearAttr;
      {[col;dir] p:i.dpath[dir;col]; p set `#get p}[col] each dirs;
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=46 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): clearAttr handler"
```

---

## Task 8: `reorderColumns` handler

**Files:**
- Modify: `src/apply.q` (`i.opTargets`, `i.runOp`)
- Modify: `_smoke_apply.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: reorderColumns ---";
rmrf "testhdb_ro"; RO:`:testhdb_ro; rod:` sv RO,`t;
(` sv rod,`a) set 1 2 3;
(` sv rod,`b) set 4 5 6;
(` sv rod,`.d) set `b`a;                       / on-disk order b,a
dro:.qm.schema[`t] (.qm.splayed[]; .qm.col[`a;`long]; .qm.col[`b;`long]);   / declared a,b
plro:.qm.plan[.qm.diff[RO;(enlist`t)!enlist dro;()!()]; (enlist`t)!enlist dro];
resro:.qm.apply[RO; plro; ()!()];
chk["reorder applied"; resro[`status]~`applied];
chk[".d reordered";    (get ` sv rod,`.d)~`a`b];
chk["data intact";     (get ` sv rod,`a)~1 2 3];
chk["re-diff ok";      `ok~(.qm.diff[RO;(enlist`t)!enlist dro;()!()])`maxSeverity];
rmrf "testhdb_ro";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: reorder checks FAIL (`unknown op` → rollback).

- [ ] **Step 3: Add the `reorderColumns` branch to `i.opTargets`**

Insert before the `op in \`setAttr\`clearAttr;` branch:

```q
    op~`reorderColumns;
      `backup`create!(i.dpath[;`.d] each dirs; ());
```

- [ ] **Step 4: Add the `reorderColumns` branch to `i.runOp`**

Insert before the `op~\`setAttr;` branch:

```q
    op~`reorderColumns;
      {[ord;dir] (i.dpath[dir;`.d]) set ord}[e[`params]`order] each dirs;
```

- [ ] **Step 5: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=50 fail=0`.

- [ ] **Step 6: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): reorderColumns handler"
```

---

## Task 9: `reEnumerate` handler

**Files:**
- Modify: `src/apply.q` (`i.opTargets`, `i.runOp`)
- Modify: `_smoke_apply.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: reEnumerate (partitioned symbol col raw on disk) ---";
rmrf "testhdb_en"; EN:`:testhdb_en;
(` sv EN,`sym) set `$();                        / empty root sym -> real HDB dir
ped:` sv EN,`2024.01.01,`q;
(` sv ped,`time) set 2#0Np;
(` sv ped,`s)    set `AA`BB;                     / RAW symbols (not enumerated)
(` sv ped,`.d)   set `time`s;
den:.qm.schema[`q] (.qm.partitioned[`date]; .qm.col[`time;`timestamp]; .qm.col[`s;`symbol]);
plen:.qm.plan[.qm.diff[EN;(enlist`q)!enlist den;()!()]; (enlist`q)!enlist den];
resen:.qm.apply[EN; plen; ()!()];
chk["reEnumerate applied"; resen[`status]~`applied];
chk["col now enum-typed";  (type get ` sv ped,`s) within 20 76h];
chk["values preserved";    `AA`BB~get[` sv EN,`sym] get ` sv ped,`s];
rmrf "testhdb_en";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: reEnumerate checks FAIL (`unknown op` → rollback).

- [ ] **Step 3: Add the `reEnumerate` branch to `i.opTargets`**

Insert before the `op in \`setAttr\`clearAttr;` branch:

```q
    op~`reEnumerate;
      `backup`create!((i.dpath[;col] each dirs),symBC 0; symBC 1);
```

- [ ] **Step 4: Add the `reEnumerate` branch to `i.runOp`**

Insert before the `op~\`setAttr;` branch:

```q
    op~`reEnumerate;
      {[root;col;dir] p:i.dpath[dir;col]; p set i.enum[root; get p]}[root;col] each dirs;
```

- [ ] **Step 5: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=53 fail=0`.

- [ ] **Step 6: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): reEnumerate handler (extend root sym)"
```

---

## Task 10: `createTable` handler — splayed

`i.entry` already builds the createTable entry (Task 3). This task adds the splayed `createTable` branches to `i.opTargets` and `i.runOp`. (The partitioned branch comes in Task 11; for now `i.runOp`'s createTable handles splayed only and throws for partitioned.)

**Files:**
- Modify: `src/apply.q` (`i.opTargets`, `i.runOp`)
- Modify: `_smoke_apply.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: createTable splayed ---";
rmrf "testhdb_ct"; CT:`:testhdb_ct;
(` sv CT,`marker) set 1 2 3;                     / make CT a real dir (no `inst yet)
dct:.qm.schema[`inst] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`u]; .qm.col[`name;`symbol]; .qm.col[`active;`boolean]);
plct:.qm.plan[.qm.diff[CT;(enlist`inst)!enlist dct;()!()]; (enlist`inst)!enlist dct];
chk["plan has createTable"; `createTable in plct[`ops]`op];
resct:.qm.apply[CT; plct; ()!()];
chk["createTable applied"; resct[`status]~`applied];
ctd:` sv CT,`inst;
chk["splayed .d";          (get ` sv ctd,`.d)~`sym`name`active];
chk["splayed empty";       0=count get ` sv ctd,`sym];
chk["re-diff ok";          `ok~(.qm.diff[CT;(enlist`inst)!enlist dct;()!()])`maxSeverity];
rmrf "testhdb_ct";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: createTable checks FAIL (`unknown op` → rollback).

- [ ] **Step 3: Add the `createTable` branch to `i.opTargets`**

Insert before the `op in \`setAttr\`clearAttr;` branch (this is the full branch; the partitioned arm is exercised in Task 11):

```q
    op~`createTable;
      $[e`isPart;
         [sdir:i.sentinelDir e`pf; partdir:` sv root,`$sdir; pdir:` sv partdir,tbl;
          hasSym:any (e[`colz]`type)~\:`symbol;
          cre:(i.dpath[pdir;] each (e[`colz]`name),`.d),enlist pdir;
          if[not (`$sdir) in key root; cre,:enlist partdir];
          `backup`create!($[hasSym;symBC 0;()]; cre,$[hasSym;symBC 1;()])];
         [dir:` sv root,tbl;
          `backup`create!((); (i.dpath[dir;] each (e[`colz]`name),`.d),enlist dir)] ];
```

- [ ] **Step 4: Add the `createTable` branch to `i.runOp`** (splayed arm live; partitioned arm a clear throw until Task 11)

Insert before the `op~\`setAttr;` branch:

```q
    op~`createTable;
      $[e`isPart;
        '"qm: apply: partitioned createTable not yet implemented";
        [dir:` sv root,tbl; colz:e`colz;
         / write each declared column as an empty typed vector, applying the declared attr
         / (so the differ doesn't see an attrChange on re-diff). `a#(empty)` is valid for any attr.
         {[dir;colz;j] v:0#first i.tnull colz[`type]j; a:colz[`attr]j; (i.dpath[dir;colz[`name]j]) set $[a~`;v;a#v]}[dir;colz] each til count colz`name;
         (i.dpath[dir;`.d]) set colz`name] ];
```

- [ ] **Step 5: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=58 fail=0`.

- [ ] **Step 6: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): createTable handler (splayed)"
```

---

## Task 11: `createTable` handler — partitioned (sentinel sample-then-truncate)

Replace the partitioned-arm throw from Task 10 with the real implementation: build a 1-row typed-null sample, write it (enumerating symbol columns, applying attrs) into the sentinel partition, then truncate every column file to 0 rows.

**Files:**
- Modify: `src/apply.q` (`i.runOp` createTable branch)
- Modify: `_smoke_apply.q`

- [ ] **Step 1: Write the failing test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: createTable partitioned (sentinel) ---";
rmrf "testhdb_cp"; CP:`:testhdb_cp;
(` sv CP,`sym) set `$();                          / real HDB dir + empty enum domain
dcp:.qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`time;`timestamp]; .qm.colx[`sym;`symbol;`attr`p]; .qm.col[`px;`float]);
plcp:.qm.plan[.qm.diff[CP;(enlist`trade)!enlist dcp;()!()]; (enlist`trade)!enlist dcp];
rescp:.qm.apply[CP; plcp; ()!()];
chk["part createTable applied"; rescp[`status]~`applied];
pdir:` sv CP,`1900.01.01,`trade;
chk["sentinel .d";        (get ` sv pdir,`.d)~`time`sym`px];
chk["sentinel empty";     0=count get ` sv pdir,`time];
chk["sym col enum-typed";  (type get ` sv pdir,`sym) within 20 76h];
chk["re-diff no newTable"; not `newTable in exec change from (.qm.diff[CP;(enlist`trade)!enlist dcp;()!()])`rows];
rmrf "testhdb_cp";
```

- [ ] **Step 2: Run to verify it fails**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: the partitioned createTable checks FAIL — `i.runOp` throws `partitioned createTable not yet implemented`, so `status` is `rolledBack`.

- [ ] **Step 3: Replace the partitioned arm in `i.runOp`'s `createTable` branch**

In `i.runOp`, replace this line:

```q
        '"qm: apply: partitioned createTable not yet implemented";
```

with the real partitioned implementation:

```q
        [colz:e`colz; pdir:` sv root,(`$i.sentinelDir e`pf),tbl;
         nms:colz`name; tps:colz`type; lst:colz`list; ats:colz`attr;
         {[root;pdir;nms;tps;lst;ats;j]
            t:tps j; isL:lst j; a:ats j;
            cell:$[isL; enlist 0#first i.tnull t; i.tnull t];          / 1-row sample cell
            v:$[(t~`symbol)&not isL; i.enum[root;cell]; cell];          / enumerate symbol cols
            v:$[a~`; v; a#v];                                          / apply declared attr
            (i.dpath[pdir;nms j]) set v }[root;pdir;nms;tps;lst;ats] each til count nms;
         (i.dpath[pdir;`.d]) set nms;
         {[pdir;c] p:i.dpath[pdir;c]; p set 0#get p}[pdir] each nms ];   / truncate to 0 rows
```

- [ ] **Step 4: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=63 fail=0`.

- [ ] **Step 5: Commit**

```
git add src/apply.q _smoke_apply.q
git commit -m "feat(apply): createTable handler (partitioned via sentinel sample-then-truncate)"
```

---

## Task 12: Rollback, multi-partition fan-out, and idempotency

Verifies the safety core end-to-end: a mid-run failure restores the HDB and removes created files; an op fans out across every partition; a second apply is a no-op.

**Files:**
- Modify: `_smoke_apply.q` (assertions only)

- [ ] **Step 1: Write the test**

Add to `_smoke_apply.q` before the final block:

```q
-1"--- apply: rollback on mid-run failure ---";
rmrf "testhdb_rb"; RB:`:testhdb_rb; rbd:` sv RB,`inst;
(` sv rbd,`name) set `x`y`z;
(` sv rbd,`sym)  set `s#`a`b`c;
(` sv rbd,`.d)   set `name`sym;
/ declared: add `extra (addColumn) AND reorder columns -> 2 ops
drb:.qm.schema[`inst] (.qm.splayed[]; .qm.col[`name;`symbol]; .qm.colx[`sym;`symbol;`attr`s]; .qm.col[`extra;`long]);
plrb:.qm.plan[.qm.diff[RB;(enlist`inst)!enlist drb;()!()]; (enlist`inst)!enlist drb];
/ force the reorderColumns op to fail, AFTER addColumn has run
realRun:.qm.i.runOp;
.qm.i.runOp:{[root;e] if[e[`op]~`reorderColumns; '"boom"]; realRun[root;e]};
dBefore:get ` sv rbd,`.d;
resrb:.qm.apply[RB; plrb; ()!()];
.qm.i.runOp:realRun;                              / restore the real handler
chk["rollback status";       resrb[`status]~`rolledBack];
chk["rollback restored .d";  (get ` sv rbd,`.d)~dBefore];
chk["rollback removed extra";not `extra in key rbd];
chk["report marks failed";   `failed in resrb[`ops]`status];
rmrf "testhdb_rb";

-1"--- apply: multi-partition fan-out + idempotency ---";
rmrf "testhdb_mp"; MP:`:testhdb_mp;
(` sv MP,`sym) set `$();
/ two partitions, table q with one col `time
{[MP;d] pd:` sv MP,(`$d),`q; (` sv pd,`time) set 2#0Np; (` sv pd,`.d) set enlist `time}[MP] each ("2024.01.01";"2024.01.02");
dmp:.qm.schema[`q] (.qm.partitioned[`date]; .qm.col[`time;`timestamp]; .qm.colx[`flag;`boolean;(enlist`default)!enlist 0b]);
plmp:.qm.plan[.qm.diff[MP;(enlist`q)!enlist dmp;()!()]; (enlist`q)!enlist dmp];
resmp:.qm.apply[MP; plmp; ()!()];
chk["fan-out applied"; resmp[`status]~`applied];
chk["flag in partition 1"; `flag in get ` sv MP,`2024.01.01,`q,`.d];
chk["flag in partition 2"; `flag in get ` sv MP,`2024.01.02,`q,`.d];
/ idempotency: re-plan + re-apply against the now-matching HDB -> noop
plmp2:.qm.plan[.qm.diff[MP;(enlist`q)!enlist dmp;()!()]; (enlist`q)!enlist dmp];
chk["idempotent noop"; (.qm.apply[MP; plmp2; ()!()])[`status]~`noop];
rmrf "testhdb_mp";
```

- [ ] **Step 2: Run to verify it passes**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: all checks `ok`, `RESULT  ok=71 fail=0`.

- [ ] **Step 3: Commit**

```
git add _smoke_apply.q
git commit -m "test(apply): rollback, partition fan-out, idempotency"
```

---

## Task 13: Document the apply layer in the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add an "Apply" section to the README**

In `README.md`, immediately after the `## Plan` section (it ends with the plan-layer design-doc link, before `## Layout`), insert:

````markdown
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
````

- [ ] **Step 2: Add the new files to the Layout section**

In the `## Layout` code block, after the `src/plan.q` line add:

```
src/apply.q       the apply layer (.qm.apply); loaded after plan.q
```

and after the `_smoke_plan.q` line add:

```
_smoke_apply.q    manual verification check for the apply layer
```

- [ ] **Step 3: Update the Testing section**

In the `## Testing` paragraph, after the sentence describing `_smoke_plan.q`, add:

```
`_smoke_apply.q` covers the apply layer — it builds throwaway HDBs, drives
diff->plan->apply for every operation, and asserts the disk result (by
re-diffing to `ok`), the backup/rollback path, dry-run, partition fan-out, and
idempotency. Run with
`QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`.
```

- [ ] **Step 4: Update the status line**

In `README.md`, change the status blockquote near the top from:

```
> **Status:** Phase 1, in development. The native q schema DSL, the differ, and the plan layer are implemented and verified; the apply / report layers are not yet built.
```

to:

```
> **Status:** Phase 1, in development. The native q schema DSL, the differ, the plan layer, and the apply layer are implemented and verified; the report layer is not yet built.
```

Also, in the opening "What it does" list, the differ bullet ends with a parenthetical `*(future)* **plan / apply**`. Update it so plan and apply are no longer described as future — change `*(future)* **plan / apply** — produce a migration plan and apply it.` to `**plan / apply** — produce a migration plan and apply it to the HDB.`

- [ ] **Step 5: Verify the harness still passes and commit**

Run: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q`
Expected: `RESULT  ok=71 fail=0` (README changes don't affect tests; this confirms nothing broke).

```
git add README.md
git commit -m "docs(apply): document the apply layer in the README"
```

---

## Final verification

- [ ] Run the apply harness: `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_apply.q -q` → `fail=0`.
- [ ] Run the plan harness (no regression): `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_plan.q -q` → `fail=0`.
- [ ] Run the differ harness (no regression): `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q` → `fail=0`.
- [ ] Run the DSL harness (no regression): `QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke.q -q` → `fail=0`.
- [ ] Confirm no stray `testhdb_*/` directories remain in the repo (`git status` clean).
