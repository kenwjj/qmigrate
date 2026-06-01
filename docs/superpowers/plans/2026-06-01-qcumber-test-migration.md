# qcumber Test Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the four `_smoke*.q` harnesses to qcumber `.quke` tests under a new `test/` folder, with qcumber + its minimal AX dependency vendored into `lib/ax/` so the suite runs on the project's KDB-X 5.0 runtime.

**Architecture:** Vendor the validated 73-`.q_` + 5-DLL qcumber closure under `lib/ax/ws/`. A pure-q runner `test/run.q` self-sets `AXLIBRARIES_HOME`+`PATH`, loads qcumber + `src/*` + `test/helpers.q`, runs `.qu.runTestFolder` over `test/`, and exits non-zero on any failure or parse error. Each `src/` layer gets one `.quke`, ported 1:1 from its smoke file; the smoke files move into `test/` unchanged as a fallback.

**Tech Stack:** q / KDB-X 5.0; qcumber (KX Developer AX libraries); PowerShell for vendoring.

**Spec:** `docs/superpowers/specs/2026-06-01-qcumber-test-migration-design.md`

**Branch:** `feat/qcumber-tests` (already created off `main`).

---

## Conventions learned from verification (apply in every `.quke`)

These were proven against the live framework on KDB-X 5.0. Violating them aborts a block.

1. **Assertions:** an `expect` passes when its q block returns `1b`. For equality use `.qu.compare[actual; expected]` (records both values on mismatch). For `in`/`count`/already-boolean checks, return the boolean directly.
2. **Expect-throws:** `1b~@[f;a;{1b}]` — true iff `f[a]` signals. Provided as `thr` in `helpers.q`.
3. **Multi-statement blocks** (`before`/`after`): **terminate every statement with `;`**. A bare multi-line block joins into a single expression and throws `'type`. Example:
   ```
   before
       rmrf "testhdb_x";
       (` sv `:testhdb_x`t`a) set 1 2 3;
       (` sv `:testhdb_x`t`.d) set enlist `a;
   ```
4. **Helpers are global:** `rmrf`, `thr`, `mkcols`, `mkrep` are loaded once by the runner from `test/helpers.q`. Do **not** define them inside blocks — block-local defs are not visible in `after`.
5. **Fixtures:** build/mutate in `before`, assert in `expect`, clean up in `after` with `rmrf` (raw `system "rmdir"` raises `'os` when the dir is absent; `rmrf` traps it). `set` to a `` ` sv `` path auto-creates parent dirs.
6. **Reserved words:** never name a block variable `all`, `type`, `attr`, `cols`, `list` (q reserved / qmigrate convention). Reuse the smoke files' `mkcols`/`mkrep` param names.
7. **`before`/`after` run once per `feature`** (not per expect) — so a mutate-then-assert section maps to one `feature` with the mutation in `before`.

---

## File Structure

- Create: `lib/ax/ws/*.q_` (73 files) + `lib/ax/ws/lib/*.dll` (5 files) — vendored qcumber.
- Create: `lib/ax/NOTICE` — provenance + KX EULA note.
- Delete: `lib/qcumber.q_` — superseded by `lib/ax/ws/qcumber.q_`.
- Create: `test/run.q` — runner.
- Create: `test/helpers.q` — global test helpers.
- Create: `test/qm.quke` `test/diff.quke` `test/plan.quke` `test/apply.quke` — ported tests.
- Move: `_smoke.q _smoke_diff.q _smoke_plan.q _smoke_apply.q` → `test/` (unchanged).
- Modify: `README.md` — Testing + Layout sections.
- Modify: `.gitignore` — ensure `testhdb*` ignored (already partially present).

---

## Task 1: Vendor qcumber into `lib/ax/`

**Files:**
- Create: `lib/ax/ws/` (73 `.q_`), `lib/ax/ws/lib/` (5 `.dll`), `lib/ax/NOTICE`

- [ ] **Step 1: Build a temp full AX home from the local install (read-only source)**

Run (PowerShell):
```powershell
$src = "C:\q\developer-1.5.4-windows\ax-libraries\ws"
$full = Join-Path $env:TEMP "axfull\ws"
New-Item -ItemType Directory -Force $full,(Join-Path $full "lib") | Out-Null
Copy-Item (Join-Path $src "*.q_") $full -Force
Copy-Item (Join-Path $src "lib\win_x64\*") (Join-Path $full "lib") -Force
"q_ in full: " + (Get-ChildItem $full -Filter *.q_).Count
```
Expected: `q_ in full: 191`.

- [ ] **Step 2: Dump the exact import closure**

Create `_closure.q` at repo root:
```q
ax:ssr[getenv[`TMP],"\\axfull";"\\";"/"];
`AXLIBRARIES_HOME setenv ax;
`PATH setenv ax,"/ws/lib;",getenv`PATH;
system "l ",ax,"/ws/qcumber.q_";
bn:{last "/" vs string x};
files:distinct (bn each .aximport.loaded),enlist "qcumber.q_";
`:_closure.txt 0: files;
-1 "closure files: ",string count files;
exit 0
```
Run: `$env:QLIC="C:\q"; $env:QHOME="C:\q"; & C:\q\w64\q.exe _closure.q -q`
Expected: `closure files: 73`.

- [ ] **Step 3: Copy the closure `.q_` + 5 DLLs into the repo**

Run (PowerShell):
```powershell
$src = "C:\q\developer-1.5.4-windows\ax-libraries\ws"
$dst = "C:\Users\Kenwjj\Documents\Git Repos\qmigrate\lib\ax\ws"
New-Item -ItemType Directory -Force $dst,(Join-Path $dst "lib") | Out-Null
Get-Content "C:\Users\Kenwjj\Documents\Git Repos\qmigrate\_closure.txt" | ForEach-Object {
  Copy-Item (Join-Path $src $_) (Join-Path $dst $_) -Force }
foreach ($d in @("q_fs.dll","q_pcre.dll","q_pcre2.dll","q_util.dll","pcre2-8.dll")) {
  Copy-Item (Join-Path $src "lib\win_x64\$d") (Join-Path $dst "lib\$d") -Force }
"q_ vendored: " + (Get-ChildItem $dst -Filter *.q_).Count
"dll vendored: " + (Get-ChildItem (Join-Path $dst 'lib') -Filter *.dll).Count
```
Expected: `q_ vendored: 73`, `dll vendored: 5`.

- [ ] **Step 4: Write `lib/ax/NOTICE`**

Create `lib/ax/NOTICE`:
```
These files are a minimal subset of the KX Developer "AX libraries" suite
(qcumber and its load-time dependency closure), extracted from a local
KX Developer 1.5.4 installation for use as this project's test framework.

They are proprietary to KX Systems and licensed under the KX EULA. They are
NOT covered by this repository's license and must NOT be redistributed outside
this private repository. Source: KX Developer (https://code.kx.com/developer).

Provenance: ax-libraries/ws/{*.q_ closure of qcumber.q_} + ws/lib/win_x64/
{q_fs,q_pcre,q_pcre2,q_util,pcre2-8}.dll, relocated to ws/lib/ so the AX loader
resolves them on KDB-X 5.0 (.z.o=`w64).
```

- [ ] **Step 5: Verify the vendored set loads in isolation**

Create `_vprobe.q` at repo root:
```q
root:ssr[first system "cd";"\\";"/"];
ax:root,"/lib/ax";
`AXLIBRARIES_HOME setenv ax;
`PATH setenv ax,"/ws/lib;",getenv`PATH;
system "l ",ax,"/ws/qcumber.q_";
-1 "loaded ok; runTestFile present: ",string `.qu.runTestFile in key `.qu;
exit 0
```
Run from repo root: `$env:QLIC="C:\q"; $env:QHOME="C:\q"; & C:\q\w64\q.exe _vprobe.q -q`
Expected: prints `loaded ok; runTestFile present: 1` with **no** "Error loading" lines.

- [ ] **Step 6: Remove scratch files and commit**

```powershell
Remove-Item -Force _closure.q,_closure.txt,_vprobe.q -ErrorAction SilentlyContinue
git add lib/ax
git commit -m "test(deps): vendor minimal qcumber AX subset under lib/ax"
```

---

## Task 2: Move smoke files into `test/`; drop the loose manifest

**Files:**
- Move: `_smoke*.q` → `test/`
- Delete: `lib/qcumber.q_`

- [ ] **Step 1: Move the four smoke files (preserve history)**

```powershell
New-Item -ItemType Directory -Force "test" | Out-Null
git mv -k _smoke.q test/_smoke.q 2>$null; if (-not (Test-Path test/_smoke.q)) { Move-Item _smoke.q test/ }
foreach ($f in "_smoke_diff.q","_smoke_plan.q","_smoke_apply.q") {
  if (Test-Path $f) { Move-Item $f (Join-Path "test" $f) -Force } }
Get-ChildItem test
```
(The smoke files are untracked/loose, so plain `Move-Item` is correct; `git mv` only applies if already tracked.)
Expected: `test/` contains the four `_smoke*.q`.

- [ ] **Step 2: Confirm a moved smoke file still runs from repo root**

Run: `$env:QLIC="C:\q"; $env:QHOME="C:\q"; & C:\q\w64\q.exe test/_smoke.q -q`
Expected: ends with `RESULT  ok=29 fail=0` (its `\l src/qm.q` paths are CWD-relative; run from repo root).

- [ ] **Step 3: Delete the loose manifest (superseded by `lib/ax/ws/qcumber.q_`)**

```powershell
Remove-Item -Force lib/qcumber.q_
```

- [ ] **Step 4: Commit**

```powershell
git add -A
git commit -m "test: relocate _smoke*.q into test/; drop loose qcumber manifest"
```

---

## Task 3: Create `test/helpers.q`

**Files:**
- Create: `test/helpers.q`

- [ ] **Step 1: Write the helpers (lifted verbatim from the smoke files)**

Create `test/helpers.q`:
```q
/ Shared test helpers, loaded globally by test/run.q before .qu.runTestFolder.
/ Defined as globals so before/expect/after blocks in every .quke can use them.

/ thr[f;a] -> 1b iff f[a] signals (expect-throws)
thr:{[f;a] 1b~@[f;a;{[e]1b}] };

/ rmrf[d] -> recursively delete dir d, tolerant of absence (traps 'os).
/ d passed in explicitly: a q lambda's free vars resolve to globals, not the
/ enclosing local, so the naive form silently no-ops. See _smoke_apply.q note.
rmrf:{[d] @[{[d] system $[.z.o like "w*";"rmdir /s /q ",ssr[d;"/";"\\"];"rm -rf ",d]}; d; {}] };

/ mkcols / mkrep: build a section-6 columns table / table report for differ tests.
/ Param names avoid q reserved words (type,list,attr,cols,names).
mkcols:{[nms;typs;lsts;atts;enms]
  flip `name`type`list`attr`default`defaultFn`enum!(
    nms; typs; lsts; atts; count[nms]#(::); count[nms]#`; enms) };
mkrep:{[nm;kind;pf;c] `name`kind`partitionField`columns!(nm;kind;pf;c) };
```

- [ ] **Step 2: Commit**

```powershell
git add test/helpers.q
git commit -m "test: add shared qcumber test helpers (thr, rmrf, mkcols, mkrep)"
```

---

## Task 4: Create the runner `test/run.q`

**Files:**
- Create: `test/run.q`

- [ ] **Step 1: Write the runner**

Create `test/run.q`:
```q
/ qcumber runner. Run from repo root:  q test/run.q -q
/ Self-configures the vendored AX env (verified: in-process setenv of
/ AXLIBRARIES_HOME + PATH is honoured by native-DLL loads), loads qcumber,
/ the project under test, and the test helpers, then runs every *.quke in test/.

root:ssr[$[.z.o like "w*"; first system "cd"; first system "pwd"]; "\\"; "/"];
ax:root,"/lib/ax";
psep:$[.z.o like "w*"; ";"; ":"];
`AXLIBRARIES_HOME setenv ax;
`PATH setenv (ax,"/ws/lib"),psep,getenv`PATH;
system "l ",ax,"/ws/qcumber.q_";

/ project under test, in dependency order
system "l ",root,"/src/qm.q";
system "l ",root,"/src/diff.q";
system "l ",root,"/src/plan.q";
system "l ",root,"/src/apply.q";
system "l ",root,"/test/helpers.q";

r:.qu.runTestFolder hsym `$root,"/test";
-1 "";
-1 "qcumber: TOTAL=",string[count r`allTestResults],
   " FAIL=",string[count r`allFailedTestResults],
   " PARSEERR=",string count r`parseErrorList;
exit count[r`allFailedTestResults]+count r`parseErrorList;
```

- [ ] **Step 2: Add a temporary smoke `.quke` to prove runner + exit gate**

Create `test/_runner_check.quke`:
```
feature runner self-check
    should pass and fail deterministically
        expect a pass
            1b
        expect a compare pass
            .qu.compare[2+2;4]
```
Run: `$env:QLIC="C:\q"; $env:QHOME="C:\q"; & C:\q\w64\q.exe test/run.q -q; echo "exit=$LASTEXITCODE"`
Expected: `TOTAL=2 FAIL=0 PARSEERR=0` and `exit=0`.

- [ ] **Step 3: Prove the gate fails on a failing expect**

Temporarily append to `test/_runner_check.quke`:
```
        expect a deliberate fail
            .qu.compare[1;2]
```
Run the same command.
Expected: `TOTAL=3 FAIL=1` and `exit=1`.

- [ ] **Step 4: Remove the temporary check file**

```powershell
Remove-Item -Force test/_runner_check.quke
```

- [ ] **Step 5: Commit**

```powershell
git add test/run.q
git commit -m "test: add pure-q qcumber runner with non-zero exit gate"
```

---

## Task 5: Port `_smoke.q` → `test/qm.quke`

**Files:**
- Create: `test/qm.quke`
- Reference (source of assertions): `test/_smoke.q`

This is the worked exemplar — full content below. Other layers follow the same shape.

- [ ] **Step 1: Write `test/qm.quke`**

Create `test/qm.quke`:
```
feature DSL: build schemas (positive)
    before
        .t.tr: .qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`time;`timestamp]; .qm.colx[`sym;`symbol;`attr`p]; .qm.col[`price;`float]; .qm.col[`size;`long]; .qm.colx[`exchange;`symbol;`default`attr!(`NYSE;`g)]);
        .t.ex: first ?[.t.tr`columns;enlist(=;`name;enlist`exchange);0b;()];
        .t.sy: first ?[.t.tr`columns;enlist(=;`name;enlist`sym);0b;()];
        .t.ob: .qm.schema[`orderbook] (.qm.partitioned[`date]; .qm.col[`time;`timestamp]; .qm.colx[`sym;`symbol;`attr`p]; .qm.colx[`bid_prices;`float;`list`true]);
        .t.bp: first ?[.t.ob`columns;enlist(=;`name;enlist`bid_prices);0b;()];
        .t.cf: .qm.schema[`config] (.qm.memory[]; .qm.colx[`key;`symbol;`attr`u]; .qm.col[`value;`string]);
        .t.df: .qm.schema[`tr] (.qm.partitioned[`date]; .qm.col[`time;`timestamp]; .qm.colx[`load_date;`date;`defaultFn`.user.computeLoadDate]);
        .t.ld: first ?[.t.df`columns;enlist(=;`name;enlist`load_date);0b;()];
    should classify the trade schema
        expect trade name
            .qu.compare[.t.tr`name; `trade]
        expect trade kind
            .qu.compare[.t.tr`kind; `partitioned]
        expect trade partitionField
            .qu.compare[.t.tr`partitionField; `date]
        expect trade has 5 cols
            .qu.compare[count .t.tr`columns; 5]
        expect exchange default
            .qu.compare[.t.ex`default; `NYSE]
        expect exchange attr g
            .qu.compare[.t.ex`attr; `g]
        expect sym attr p
            .qu.compare[.t.sy`attr; `p]
        expect plain col attr empty
            .qu.compare[(first ?[.t.tr`columns;enlist(=;`name;enlist`time);0b;()])`attr; `]
    should classify list-ness and shapes
        expect list`true coerces to 1b
            .qu.compare[.t.bp`list; 1b]
        expect non-list col is 0b
            .qu.compare[(first ?[.t.ob`columns;enlist(=;`name;enlist`time);0b;()])`list; 0b]
        expect memory kind
            .qu.compare[.t.cf`kind; `memory]
        expect memory partitionField empty
            .qu.compare[.t.cf`partitionField; `]
        expect defaultFn stored
            .qu.compare[.t.ld`defaultFn; `.user.computeLoadDate]
        expect defaultFn default is ::
            (::)~.t.ld`default
    after
        delete t from `
feature DSL: validation throws (spec section 7)
    should signal on invalid schemas
        expect unknown type
            thr[.qm.schema[`t];(.qm.memory[];.qm.col[`x;`notatype])]
        expect string cannot be a list
            thr[.qm.schema[`t];(.qm.memory[];.qm.colx[`x;`string;`list`true])]
        expect unknown modifier key
            thr[.qm.colx[`x;`int];enlist`foo`bar]
        expect both default and defaultFn
            thr[.qm.schema[`t];(.qm.memory[];.qm.colx[`x;`int;`default`defaultFn!(5;`f)])]
        expect invalid attr
            thr[.qm.schema[`t];(.qm.memory[];.qm.colx[`x;`int;`attr`z])]
        expect duplicate col names
            thr[.qm.schema[`t];(.qm.memory[];.qm.col[`x;`int];.qm.col[`x;`long])]
        expect no shape
            thr[.qm.schema[`t];enlist .qm.col[`x;`int]]
        expect two shapes
            thr[.qm.schema[`t];(.qm.memory[];.qm.splayed[];.qm.col[`x;`int])]
        expect no cols
            thr[.qm.schema[`t];enlist .qm.memory[]]
        expect name not symbol
            thr[.qm.schema["t"];(.qm.memory[];.qm.col[`x;`int])]
        expect shorthand bad length
            thr[.qm.colx[`x;`int];enlist`a`b`c]
        expect defaultFn not symbol
            thr[.qm.schema[`t];(.qm.memory[];.qm.colx[`x;`int;(enlist`defaultFn)!enlist 5])]
feature DSL: loadSchemas
    before
        .t.s: .qm.loadSchemas `:schemas;
    should load the schemas directory
        expect loaded 4 tables
            .qu.compare[count .t.s; 4]
        expect keys are the table names
            .qu.compare[asc key .t.s; `config`instruments`orderbook`trade]
        expect instruments is splayed
            .qu.compare[.t.s[`instruments;`kind]; `splayed]
    after
        delete t from `
```

- [ ] **Step 2: Run the suite and verify qm.quke is green**

Run: `$env:QLIC="C:\q"; $env:QHOME="C:\q"; & C:\q\w64\q.exe test/run.q -q; echo "exit=$LASTEXITCODE"`
Expected: `TOTAL=29 FAIL=0 PARSEERR=0`, `exit=0` (29 = the count of `chk`/`thr` in `_smoke.q`).

- [ ] **Step 3: Commit**

```powershell
git add test/qm.quke
git commit -m "test: port DSL smoke checks to test/qm.quke"
```

---

## Task 6: Port `_smoke_diff.q` → `test/diff.quke`

**Files:**
- Create: `test/diff.quke`
- Reference: `test/_smoke_diff.q` (the authoritative list of assertions)

Port rules: one `feature` per `--- ... ---` section in `_smoke_diff.q`; each `chk[d;x~y]` → `expect d` / `.qu.compare[x;y]`; each `chk[d;cond]` (uses `in`/`count`/`select`) → `expect d` / `cond`; each `thr[...]` → `expect ...` / `thr[...]`. `mkcols`/`mkrep` come from `helpers.q`. The only fixture with disk I/O is the `build fixture HDB ./testhdb` section onward — put its construction in a `before` and `rmrf "testhdb"` in `after`.

- [ ] **Step 1: Write the pure-comparison features (no disk)**

These sections build in-memory `decl`/`act` reports and compare. Write one `feature` per section: `compare: newTable`, `compare: columns`, `compare: table-level`, `compare: enum`, `compare: end-to-end pure`, `rollup + opts`. For each, set the section's report vars in a `before` (semicolon-terminated), then one `expect` per `chk`. Example for the `columns` section:
```
feature diff: compare columns
    before
        .t.decl: mkrep[`t;`splayed;`] mkcols[`a`b`c; `long`symbol`float; 000b; ``g`; 000b];
        .t.act:  mkrep[`t;`splayed;`] mkcols[`a`b`d; `long`symbol`int;  000b; ```; 000b];
        .t.rc: .qm.i.cmpCols[.t.decl;.t.act];
        .t.decl2: mkrep[`t;`splayed;`] mkcols[enlist`a; enlist`float; enlist 1b; enlist`; enlist 0b];
        .t.act2:  mkrep[`t;`splayed;`] mkcols[enlist`a; enlist`long;  enlist 0b; enlist`; enlist 0b];
        .t.rc2: .qm.i.cmpCols[.t.decl2;.t.act2];
    should detect add/drop/attr changes
        expect addColumn c
            `addColumn in exec change from .t.rc where column=`c
        expect dropColumn d
            `dropColumn in exec change from .t.rc where column=`d
        expect attrChange b
            `attrChange in exec change from .t.rc where column=`b
        expect no typeChange
            .qu.compare[0; count select from .t.rc where change=`typeChange]
    should detect type/list change on a
        expect typeChange a
            `typeChange in exec change from .t.rc2 where column=`a
        expect listChange a
            `listChange in exec change from .t.rc2 where column=`a
        expect typeChange is destructive
            `destructive in exec severity from .t.rc2 where change=`typeChange
    after
        delete t from `
```
Port the remaining no-disk sections (`newTable`, `table-level`, `enum`, `end-to-end pure`, `rollup + opts`) the same way, one `expect` per `chk`/`thr` in `_smoke_diff.q`. The `rollup + opts` section includes two `thr` checks (`normOpts unknown throws`) → `expect ... thr[...]`.

- [ ] **Step 2: Write the disk-fixture features (introspect / diffTable / diff)**

Build the `./testhdb` fixture once in a `before`, assert across the `introspect`, `diffTable`, and `diff` sections, clean in `after`. Because `before`/`after` are per-feature, put the whole HDB lifecycle + all its assertions in ONE feature so the fixture is built once:
```
feature diff: against on-disk HDB ./testhdb
    before
        rmrf "testhdb";
        .t.HDB: `:testhdb;
        {[hdb;d] t:([] time:2#.z.p; sym:`A`B; bids:(1 2f;3 4f); note:("x";"yy"); px:1.0 2.0); (` sv hdb,(`$string d),`quote,`) set .Q.en[hdb;t]; }[.t.HDB] each 2025.01.01 2025.01.02;
        system "mkdir ",ssr[1_string ` sv .t.HDB,`ref,`; "/"; "\\"];
        (` sv .t.HDB,`ref,`sym)    set `s#`AA`BB;
        (` sv .t.HDB,`ref,`label)  set `x`y;
        (` sv .t.HDB,`ref,`active) set 01b;
        (` sv .t.HDB,`ref,`.d)     set `sym`label`active;
        .t.dq: .qm.schema[`quote] (.qm.partitioned[`date]; .qm.col[`time;`timestamp]; .qm.colx[`sym;`symbol;`attr`g]; .qm.colx[`bids;`float;`list`true]; .qm.col[`note;`string]; .qm.col[`px;`float]);
        .t.iq: .qm.i.introspect[.t.HDB;`quote];
        .t.ir: .qm.i.introspect[.t.HDB;`ref];
        .t.res: .qm.diffTable[.t.HDB; .t.dq; ()!()];
    should introspect on-disk tables
        expect quote is partitioned
            .qu.compare[.t.iq`kind; `partitioned]
        ...one expect per introspect chk...
    should diffTable + diff classify correctly
        ...one expect per diffTable/diff chk...
    after
        rmrf "testhdb"
```
Port **every** `chk` from the `introspect`, `diffTable`, `diff (whole HDB)`, and `diff: destructive + opt-in` sections as `expect`s under this feature (set any extra vars like `.t.resa`/`.t.resd`/`.t.dqd`/`.t.decls`/`.t.dfills` in the `before`). The `thr` checks (`diffTable bad path throws`) → `expect ... thr[...]`.

- [ ] **Step 3: Run and verify**

Run: `$env:QLIC="C:\q"; $env:QHOME="C:\q"; & C:\q\w64\q.exe test/run.q -q; echo "exit=$LASTEXITCODE"`
Expected: `FAIL=0 PARSEERR=0`, `exit=0`. The combined `TOTAL` equals (qm.quke 29) + (count of `chk`/`thr` in `_smoke_diff.q`). Verify the diff portion's expect count matches the smoke file's assertion count (grep `chk\[` and `thr\[` in `_smoke_diff.q`).

- [ ] **Step 4: Commit**

```powershell
git add test/diff.quke
git commit -m "test: port differ smoke checks to test/diff.quke"
```

---

## Task 7: Port `_smoke_plan.q` → `test/plan.quke`

**Files:**
- Create: `test/plan.quke`
- Reference: `test/_smoke_plan.q`

Same rules. Sections: `empty diff`, `input validation` (two `thr`), `createTable`, `addColumn`, `attrChange`, `dropColumn`, `reorderColumns`, `reEnumerate`, `manual (recreate-class)`, `ordering + no-ops`, `unmanaged + skipped`, `end-to-end against temp HDB`, `destructive applyable propagation`. The early sections build differ-result rows via `.qm.i.rollupWith`/`.qm.i.row`/`.qm.i.normOpts` (no disk) — one `feature` each, vars in `before`. The last two sections build a `testhdb_plan` HDB — wrap each in its own feature with `rmrf "testhdb_plan"` in `before` and `after`.

- [ ] **Step 1: Write the no-disk plan features**

One `feature` per section; set the section's `dr*`/`p*`/`rows*`/`d*` vars in `before` (semicolon-terminated), one `expect` per `chk`. Example:
```
feature plan: createTable
    before
        .t.dtrade: .qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`time;`timestamp]; .qm.colx[`sym;`symbol;`attr`p]; .qm.col[`price;`float]);
        .t.drNew: .qm.i.rollupWith[.qm.i.row[`trade;`;`newTable;::;`partitioned;"absent"]; .qm.i.normOpts[()!()]];
        .t.pNew: .qm.plan[.t.drNew; (enlist`trade)!enlist .t.dtrade];
    should produce one createTable op
        expect 1 op
            .qu.compare[count .t.pNew`ops; 1]
        expect op type createTable
            .qu.compare[first .t.pNew[`ops]`op; `createTable]
        ...one expect per chk in the createTable section...
    after
        delete t from `
```
The `input validation` section's two `chk[...;thr[...]]` → `expect ... thr[...]`.

- [ ] **Step 2: Write the two temp-HDB features**

`end-to-end against a temp HDB` and `destructive applyable propagation` both use `testhdb_plan`. Build the splayed `inst` on disk in `before`, assert, `rmrf "testhdb_plan"` in `after`. Mirror the smoke's construction (the `system "mkdir ..."` + `set` lines), one `expect` per `chk`.

- [ ] **Step 3: Run and verify**

Run the suite. Expected `FAIL=0 PARSEERR=0 exit=0`; plan expect count matches `chk`/`thr` count in `_smoke_plan.q`.

- [ ] **Step 4: Commit**

```powershell
git add test/plan.quke
git commit -m "test: port plan-layer smoke checks to test/plan.quke"
```

---

## Task 8: Port `_smoke_apply.q` → `test/apply.quke`

**Files:**
- Create: `test/apply.quke`
- Reference: `test/_smoke_apply.q`

Every section here builds a fresh `testhdb_*`, mutates it, then asserts — so each `--- ... ---` section maps to **one `feature`** with the build+mutation (incl. the `.qm.apply` call) in `before`, the disk assertions as `expect`s, and `rmrf "<dir>"` in `after`. The two sections that monkeypatch `.qm.i.runOp` / `.qm.i.enum` to force mid-run failure must save and restore the original inside the `before` (set the patched fn, run apply, restore) so other features are unaffected.

- [ ] **Step 1: Write the helper/backup features (no apply call)**

`low-level helpers` and `backup / restore / delete-created` sections: build the dir in `before`, assert helper outputs in `expect`, `rmrf` in `after`. Example:
```
feature apply: low-level helpers
    before
        rmrf "testhdb_apply";
        .t.R: `:testhdb_apply;
        .t.sd: ` sv .t.R,`inst;
        (` sv .t.sd,`sym) set `AA`BB`CC;
        (` sv .t.sd,`px)  set 1 2 3f;
        (` sv .t.sd,`.d)  set `sym`px;
    should expose introspection helpers
        expect getD
            .qu.compare[.qm.i.getD .t.sd; `sym`px]
        expect rowCount 3
            .qu.compare[.qm.i.rowCount .t.sd; 3]
        ...one expect per chk in the section...
    after
        rmrf "testhdb_apply"
```

- [ ] **Step 2: Write the diff→plan→apply features**

For each remaining section (`gate / noop / dryRun / setAttr`, `addColumn`, `addColumn defaultFn + preflight throws`, `dropColumn`, `clearAttr`, `reorderColumns`, `reEnumerate`, `createTable splayed`, `createTable partitioned`, `rollback on mid-run failure`, `multi-partition fan-out + idempotency`, `rollback tolerates mid-fan-out`): one feature, fixture+`.qm.diff`/`.qm.plan`/`.qm.apply` in `before`, disk assertions as `expect`s, `rmrf` in `after`. `thr` checks (`bad opts throws`, `malformed plan throws`, `missing defaultFn throws`, `unsatisfiable attr throws`) → `expect ... thr[...]`. For the monkeypatch sections:
```
feature apply: rollback on mid-run failure
    before
        rmrf "testhdb_rb";
        .t.RB: `:testhdb_rb; .t.rbd: ` sv .t.RB,`inst;
        (` sv .t.rbd,`name) set `x`y`z;
        (` sv .t.rbd,`sym)  set `s#`a`b`c;
        (` sv .t.rbd,`.d)   set `name`sym;
        .t.drb: .qm.schema[`inst] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`s]; .qm.col[`name;`symbol]; .qm.col[`extra;`long]);
        .t.plrb: .qm.plan[.qm.diff[.t.RB;(enlist`inst)!enlist .t.drb;()!()]; (enlist`inst)!enlist .t.drb];
        .t.realRun: .qm.i.runOp;
        .qm.i.runOp:{[root;e] if[e[`op]~`reorderColumns; '"boom"]; .t.realRun[root;e]};
        .t.dBefore: get ` sv .t.rbd,`.d;
        .t.resrb: .qm.apply[.t.RB; .t.plrb; ()!()];
        .qm.i.runOp: .t.realRun;
    should roll back cleanly
        expect status rolledBack
            .qu.compare[.t.resrb`status; `rolledBack]
        expect .d restored
            .qu.compare[get ` sv .t.rbd,`.d; .t.dBefore]
        expect extra removed
            not `extra in key .t.rbd
        expect report marks failed
            `failed in .t.resrb[`ops]`status
    after
        rmrf "testhdb_rb"
```
(Note: the patched lambda references `.t.realRun` — a global — instead of the smoke's local `realRun`, because block scope differs; this is the same global-helper rule from the conventions.)

- [ ] **Step 3: Run and verify**

Run the suite. Expected `FAIL=0 PARSEERR=0 exit=0`. Confirm no `testhdb_*` dirs are left behind (`Get-ChildItem -Directory -Filter testhdb_*`); apply expect count matches `chk`/`thr` in `_smoke_apply.q`.

- [ ] **Step 4: Commit**

```powershell
git add test/apply.quke
git commit -m "test: port apply-layer smoke checks to test/apply.quke"
```

---

## Task 9: Update README and .gitignore

**Files:**
- Modify: `README.md` (Testing + Layout sections)
- Modify: `.gitignore`

- [ ] **Step 1: Update the Layout section**

In `README.md`, replace the `_smoke*.q` lines in the Layout block with:
```
test/run.q        qcumber runner: q test/run.q -q (exits non-zero on any failure)
test/helpers.q    shared test helpers (thr, rmrf, mkcols, mkrep)
test/*.quke       qcumber tests, one per src layer (qm, diff, plan, apply)
test/_smoke*.q    original hand-rolled harnesses, kept as a dependency-free fallback
lib/ax/           vendored minimal qcumber (KX AX libraries; proprietary — see lib/ax/NOTICE)
```

- [ ] **Step 2: Rewrite the Testing section**

Replace the Testing section body with:
```
The test suite uses **qcumber** (`.quke` BDD files). Run it from the repo root:

    q test/run.q -q

The runner loads the vendored qcumber under `lib/ax/`, loads `src/*` and
`test/helpers.q`, runs every `*.quke` in `test/`, and exits non-zero on any
failed expectation or parse error. `test/{qm,diff,plan,apply}.quke` cover the
DSL, differ, plan, and apply layers respectively.

> qcumber is the KX Developer AX library suite. It does not officially support
> KDB-X 5.0 (the IDE rejects v5), but the standalone runner has no version gate;
> a minimal subset is vendored under `lib/ax/` with the Windows native libs
> relocated to `ws/lib/` so the AX loader resolves them. Windows-only. See
> `lib/ax/NOTICE` (proprietary; private repo only).

The `test/_smoke*.q` files remain as a dependency-free fallback (e.g.
`q test/_smoke.q -q`), each exiting non-zero on failure.
```

- [ ] **Step 3: Ensure testhdb dirs are ignored**

Confirm `.gitignore` contains `testhdb*` (the apply work already added `testhdb_*`). If only `testhdb_*` is present, add a line `testhdb` and `testhdb*/` to cover the differ's `./testhdb` fixture. Run:
```powershell
Get-Content .gitignore | Select-String testhdb
```
Add any missing pattern.

- [ ] **Step 4: Commit**

```powershell
git add README.md .gitignore
git commit -m "docs: document the qcumber test suite; ignore testhdb fixtures"
```

---

## Task 10: Full-suite verification

- [ ] **Step 1: Run the whole suite from a clean tree**

```powershell
git status --short
$env:QLIC="C:\q"; $env:QHOME="C:\q"; & C:\q\w64\q.exe test/run.q -q; echo "exit=$LASTEXITCODE"
```
Expected: `FAIL=0 PARSEERR=0`, `exit=0`, and `TOTAL` = sum of all four layers' assertion counts.

- [ ] **Step 2: Confirm no fixtures leaked and tree is clean**

```powershell
Get-ChildItem -Directory -Filter testhdb*
git status --short
```
Expected: no `testhdb*` directories; working tree clean (all committed).

- [ ] **Step 3: Cross-check parity with the smoke files**

For each layer, confirm the qcumber expect count equals the source smoke assertion count:
```powershell
foreach ($f in "_smoke","_smoke_diff","_smoke_plan","_smoke_apply") {
  $n = (Select-String -Path "test/$f.q" -Pattern 'chk\[|thr\[' -AllMatches | Measure-Object).Count
  "$f : $n assertions" }
```
The combined `TOTAL` from Step 1 should equal the sum of these counts.

---

## Self-review notes

- **Spec coverage:** vendoring (Task 1), runner+exit gate (Task 4), helpers (Task 3), per-layer `.quke` (Tasks 5-8), moved smoke fallback (Task 2), README/Layout (Task 9), branch (pre-created). All spec sections map to a task.
- **No placeholders:** infra files (NOTICE, helpers.q, run.q) and `qm.quke` are given in full; diff/plan/apply provide full fixtures + representative features and port the remaining `expect`s 1:1 from the in-repo smoke source per the explicit mapping rules, with assertion-count parity as the verification gate.
- **Consistency:** runner exit gate `count allFailedTestResults + count parseErrorList`; helpers are globals; `.t.*` namespace for fixture vars; `rmrf`/`thr`/`mkcols`/`mkrep` signatures match `helpers.q` everywhere.
