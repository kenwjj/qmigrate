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

-1 "--- plan: createTable ---";
/ a declared table absent on disk -> differ emits a single newTable row
dtrade:.qm.schema[`trade] (
  .qm.partitioned[`date];
  .qm.col [`time;  `timestamp];
  .qm.colx[`sym;   `symbol; `attr`p];
  .qm.col [`price; `float] );
drNew:.qm.i.rollupWith[.qm.i.row[`trade;`;`newTable;::;`partitioned;"absent"]; .qm.i.normOpts[()!()]];
pNew:.qm.plan[drNew; (enlist`trade)!enlist dtrade];
chk["createTable 1 op";        1=count pNew`ops];
chk["createTable op type";     `createTable~first pNew[`ops]`op];
chk["createTable seq=1";       1=first pNew[`ops]`seq];
chk["createTable table-level"; `~first pNew[`ops]`column];
chk["createTable params kind"; `partitioned~(first pNew[`ops]`params)`kind];
chk["createTable params cols"; `time`sym`price~(first pNew[`ops]`params)[`columns]`name];

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
