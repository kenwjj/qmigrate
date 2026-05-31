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
