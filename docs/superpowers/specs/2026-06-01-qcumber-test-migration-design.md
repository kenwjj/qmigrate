# qcumber test-migration design

**Status:** Approved (design) — 2026-06-01
**Author:** Kenneth Wong (with Claude)
**Scope:** Migrate the four hand-rolled `_smoke*.q` harnesses to the qcumber (`.quke`) BDD framework under a new `test/` folder, with qcumber and its dependencies vendored into the repo so the suite runs on the project's own KDB-X 5.0 runtime.

---

## 1. Context

`qmigrate` currently verifies its four layers with hand-rolled harnesses at the repo
root:

| File | Covers | src |
|------|--------|-----|
| `_smoke.q` | the `.qm` schema DSL | `src/qm.q` |
| `_smoke_diff.q` | the differ | `src/diff.q` |
| `_smoke_plan.q` | the plan layer | `src/plan.q` |
| `_smoke_apply.q` | the apply layer | `src/apply.q` |

Each defines a `chk[desc;cond]` assertion, a `thr[f;a]` "expect-throws" helper, prints
`RESULT ok=.. fail=..`, and `exit fail` (non-zero on any failure). The diff/plan/apply
harnesses build throwaway HDBs under `testhdb*` and clean them up.

The README's *Testing* section calls these "temporary hand-rolled harnesses" and notes
"A proper framework is still to be chosen." The user has chosen **qcumber**.

## 2. Investigation findings (why this is non-trivial)

qcumber is **not** a drop-in library. Findings, all verified by running q against the
local install (KX Developer 1.5.4 at `C:\q\developer-1.5.4-windows`) on KDB-X 5.0:

1. The `lib/qcumber.q_` the user placed (2048 bytes) is **byte-identical** to the
   install's `ax-libraries/ws/qcumber.q_`. It is only a **bootstrap manifest** — it
   imports its implementation from sibling modules and cannot run alone.
2. Real qcumber is part of the **KX Developer AX library suite**: a large set of
   interlocking `.q_` modules (`.qu.*`, `.ax*`, `.qch*`, `.pcre/.pcre2`, …) plus
   per-platform native libraries, resolved through `AXLIBRARIES_HOME` by an
   `.aximport` loader.
3. **The IDE rejects KDB-X 5.0** (`"kdb+ version 5 is not supported - supported
   versions are 4.1 4.0 3.6 3.5 3.4"`; acknowledged by KX staff on the community forum
   2026-05-21, no fix/ETA). **However, that version gate lives only in the IDE's
   `launcher.q_`.** The standalone `qcumber.q_` test runner has **no** such gate.
4. The only real blocker on KDB-X 5.0 was **native-DLL resolution**: the AX loader
   requests `ws/lib/q_fs.dll` (no platform subdir), but the DLLs ship under
   `ws/lib/win_x64/`. Placing the Windows DLLs at `ws/lib/` (top level) and putting
   `ws/lib` on `PATH` (so `q_pcre2.dll` finds `pcre2-8.dll`) resolves it.
5. With that shim, qcumber **loads and runs correctly on KDB-X 5.0** (build
   2026.05.01, `.z.o=`w64`, `.z.K=5f`).

### Decision

Vendor a **minimal subset** of the AX suite into the repo so the test suite is
self-contained and runs on the project's actual KDB-X 5.0 runtime. The repo is
**private**, so vendoring KX-proprietary binaries is acceptable (a `NOTICE` records
provenance and that they are KX-licensed, not covered by the repo license).

Alternatives considered and rejected: run tests on kdb+ ≤4.1 (tests would run on a
different interpreter than the product ships against, and still need the KX suite);
runtime-shim from the local install (not portable, requires KX Developer installed);
a lightweight homegrown framework (user prefers qcumber's BDD/bench/property model).

## 3. Architecture

Three parts: **vendored dependency**, a **runner**, and the **`.quke` tests**.

### 3.1 Vendored dependency — `lib/ax/`

The exact import closure of `qcumber.q_` was captured from the live loader
(`.aximport.loaded`): **72 transitive modules + `qcumber.q_` = 73 `.q_` files**. It
excludes everything qcumber does not touch (graphics `.gg.*`, `.qlint.*`, `.qdoc`,
`.axtr`, timezone `zones.db`, the Skia/other-platform native libs).

Layout:

```
lib/ax/
  NOTICE                 provenance + KX EULA statement (proprietary; not under repo license)
  ws/
    qcumber.q_           entry manifest
    .qu.*.q_ .ax*.q_ .qch*.q_ .pcre*.q_ .im.*.q_ .cov.*.q_ .table.q_ …   (73 total)
    lib/
      q_fs.dll q_pcre.dll q_pcre2.dll q_util.dll pcre2-8.dll             (5 DLLs)
```

Total ≈ 2.3 MB. The DLLs are the **Windows (`win_x64`)** builds only — the suite is
therefore Windows-only, matching the project's development platform. (Adding other
platforms later means dropping their `q_*`/`libpcre2` libs into `ws/lib/` under their
own names, out of scope here.)

The user's loose `lib/qcumber.q_` is **superseded** by `lib/ax/ws/qcumber.q_` and is
removed.

### 3.2 Runner — `test/run.q`

A pure-q script (run `q test/run.q -q` from the repo root). It self-configures the AX
environment — **verified**: q's `setenv` of `AXLIBRARIES_HOME` and `PATH` before the
load is honoured by the in-process native-DLL loads, so **no shell wrapper is needed**.

Behaviour:

1. Derive the absolute repo root from the current directory (`system "cd"` on Windows /
   `system "pwd"` on \*nix, branched on `.z.o`).
2. `setenv` `AXLIBRARIES_HOME` → `<root>/lib/ax`, and prepend `<root>/lib/ax/ws/lib` to
   `PATH`.
3. `system "l <root>/lib/ax/ws/qcumber.q_"` to load qcumber.
4. Load the project under test, in dependency order:
   `\l src/qm.q` → `src/diff.q` → `src/plan.q` → `src/apply.q`.
5. `\l test/helpers.q` (shared test helpers, see §3.4).
6. `res:.qu.runTestFolder `:test` (qcumber runs every `*.quke` in `test/`; non-`.quke`
   files such as the moved `_smoke*.q` are ignored).
7. **Exit gate:** `exit count[res`allFailedTestResults] + count res`parseErrorList`.
   Zero ⇒ all tests passed and all files parsed; non-zero ⇒ failures or parse errors.
   (Confirmed: a folder with one deliberately failing expect exits `1`.)

### 3.3 Test files — one `.quke` per layer

```
test/
  run.q          the runner (above)
  helpers.q      shared test helpers
  qm.quke        from _smoke.q
  diff.quke      from _smoke_diff.q
  plan.quke      from _smoke_plan.q
  apply.quke     from _smoke_apply.q
  _smoke.q  _smoke_diff.q  _smoke_plan.q  _smoke_apply.q   (moved here unchanged; fallback)
```

One `.quke` per `src/` layer mirrors the existing one-smoke-per-layer structure and
keeps each file focused. The moved `_smoke*.q` are kept verbatim as a dependency-free
fallback (they still run via `q test/_smoke.q -q` from the repo root, since their
`\l src/qm.q` paths are CWD-relative).

### 3.4 Shared helpers — `test/helpers.q`

Defines the helpers the smoke files declared inline, loaded once by the runner so every
`.quke` can use them:

- `thr:{[f;a] 1b~@[f;a;{1b}]}` — true iff `f[a]` signals (expect-throws).
- `rmrf:{[d] …}` — recursive dir delete (the apply harness's OS-branched version,
  passing `d` explicitly — see the note already in `_smoke_apply.q`).
- `mkcols` / `mkrep` — the section-6 columns/report builders from `_smoke_diff.q`.

### 3.5 `.quke` mapping rules (smoke → quke)

qcumber `.quke` syntax is indentation-based: `feature` › `should` › `expect`, with
`before`/`after` (per-feature) and `before each`/`after each` (per-expect) setup blocks.
An `expect` passes when its q block returns `1b`; `.qu.compare[actual;expected]` yields
`1b` on match and records both values on mismatch.

| Smoke construct | `.quke` translation |
|---|---|
| `--- section ---` comment | one `feature` |
| fixture/HDB build + any mutation for that section | the feature's `before` block |
| cleanup (`rmrf`, HDB removal) | the feature's `after` block |
| `chk[d; x~y]` (equality) | `expect d` → `.qu.compare[x;y]` |
| `chk[d; cond]` (`in`/`count`/boolean) | `expect d` → `cond` |
| `thr[f;a]` | `expect …` → `1b~@[f;a;{1b}]` (via `helpers.q`) |

Because qcumber's `before`/`after` run **once per feature** (not per expect), each
apply-layer section that mutates an HDB then asserts the result maps to its own
`feature` with the build+mutation in `before` — preserving the current
"fresh `testhdb_*` per section" isolation. Assertion descriptions carry over from the
smoke `chk` description strings.

## 4. CI / exit semantics

`q test/run.q -q` exits `0` only when every expect passed and every `.quke` parsed;
otherwise non-zero — same contract as the current `exit fail`, so any CI step that runs
the smoke files can run the qcumber suite unchanged. qcumber also prints a per-test
summary to stdout (failing tests by default; all with `-showAll`).

## 5. README updates

- *Testing* section: qcumber is the framework; document `q test/run.q -q`, the vendored
  dependency under `lib/ax/`, and the EULA note. Demote `_smoke*.q` to "fallback".
- *Layout* section: add `test/` and `lib/ax/`; update the `_smoke*.q` paths.

## 6. Branch

All work on a new branch `feat/qcumber-tests` off `main`.

## 7. Out of scope

- Non-Windows native libs (suite is Windows-only for now).
- qcumber `bench` / `property` blocks — the smoke files only assert; we port asserts.
- Any change to `src/` behaviour or to the schemas.
- Rewriting assertions beyond the mechanical mapping in §3.5.

## 8. Verification already performed

On KDB-X 5.0 (`C:\q\w64\q.exe`), against a throwaway AX home built from the local
install:

- qcumber loads via the standalone `qcumber.q_` (no version gate) once the Windows DLLs
  sit at `ws/lib/` and `ws/lib` is on `PATH`.
- A pure-q runner that `setenv`s `AXLIBRARIES_HOME`+`PATH` itself loads qcumber with no
  shell help.
- The **minimal 73-`.q_` + 5-DLL** set loads with **no errors** and runs a sample
  `.quke` (3 pass, 1 deliberate fail) returning the documented result dict; the runner
  exit gate returns `1` for that one failure.
- `.qu.compare` passes on equal / fails on unequal; a raw `1b` passes; the
  `1b~@[f;a;{1b}]` throw-idiom passes.

## 9. Open questions

None blocking. Minor: the exact repo-root derivation in `test/run.q` (`system "cd"`
parsing) is finalised in the implementation plan; the env mechanism it relies on is
already proven.
