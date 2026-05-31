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
chk["createTable params partField"; `date~(first pNew[`ops]`params)`partitionField];

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
chk["addColumn exchange detail";(first ax`detail) like "*default NYSE"];   / KDB-X like has no internal `*`
al:select from pAdd[`ops] where column=`load_date;
chk["addColumn defaultFn param";`.user.computeLoadDate~(first al`params)`defaultFn];
chk["addColumn defaultFn detail"; (first al`detail) like "*computed default via*"];
chk["addColumn two ops";        2=count select from pAdd[`ops] where op=`addColumn];

-1 "--- plan: attrChange ---";
dattr:.qm.schema[`trade] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`p]; .qm.col[`px;`float]);
/ declared attr `p, disk none -> setAttr ; declared none, disk `g -> clearAttr
rowsAttr:(.qm.i.row[`trade;`sym;`attrChange;`;`p;"attr differs"]),
         (.qm.i.row[`trade;`px; `attrChange;`g;`;"attr differs"]);
pAttr:.qm.plan[.qm.i.rollupWith[rowsAttr; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist dattr];
chk["setAttr op";    `setAttr in exec op from pAttr[`ops] where column=`sym];
chk["setAttr param"; `p~(first exec params from pAttr[`ops] where column=`sym)`attr];
chk["clearAttr op";  `clearAttr in exec op from pAttr[`ops] where column=`px];
chk["clearAttr param";`g~(first exec params from pAttr[`ops] where column=`px)`from];

-1 "--- plan: dropColumn ---";
ddrop:.qm.schema[`trade] (.qm.splayed[]; .qm.col[`keep;`long]);
pDrop:.qm.plan[.qm.i.rollupWith[.qm.i.row[`trade;`gone;`dropColumn;`float;::;"on disk, not declared"]; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist ddrop];
chk["dropColumn op";       `dropColumn~first pDrop[`ops]`op];
chk["dropColumn destructive"; `destructive~first pDrop[`ops]`severity];
chk["dropColumn column";   `gone~first pDrop[`ops]`column];

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
