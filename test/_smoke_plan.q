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

-1 "--- plan: reorderColumns ---";
dord:.qm.schema[`trade] (.qm.splayed[]; .qm.col[`a;`long]; .qm.col[`b;`long]);
pOrd:.qm.plan[.qm.i.rollupWith[.qm.i.row[`trade;`;`colOrderChange;`b`a;`a`b;"different order"]; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist dord];
chk["reorderColumns op";    `reorderColumns~first pOrd[`ops]`op];
chk["reorderColumns order"; `a`b~(first pOrd[`ops]`params)`order];
chk["reorderColumns table-level"; `~first pOrd[`ops]`column];

-1 "--- plan: reEnumerate ---";
denum:.qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`sym;`symbol]);
/ differ enumMismatch row: to=1b (declared enum expected), from=0b (disk raw)
pEnum:.qm.plan[.qm.i.rollupWith[.qm.i.row[`trade;`sym;`enumMismatch;0b;1b;"enumeration state differs"]; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist denum];
chk["reEnumerate op";       `reEnumerate~first pEnum[`ops]`op];
chk["reEnumerate warning";  `warning~first pEnum[`ops]`severity];
chk["reEnumerate param";    1b~(first pEnum[`ops]`params)`enumerate];

-1 "--- plan: manual (recreate-class) ---";
dman:.qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`a;`long]);
rowsMan:(.qm.i.row[`trade;`a;`typeChange;`float;`long;"type differs"]),
        (.qm.i.row[`trade;`a;`listChange;0b;1b;"list-ness differs"]),
        (.qm.i.row[`trade;`;`kindChange;`splayed;`partitioned;"kind differs"]),
        (.qm.i.row[`trade;`;`partitionChange;`month;`date;"partition differs"]);
pMan:.qm.plan[.qm.i.rollupWith[rowsMan; .qm.i.normOpts[()!()]]; (enlist`trade)!enlist dman];
chk["manual for all 4 recreate changes"; 4=count select from pMan[`ops] where op=`manual];
chk["manual keeps destructive sev"; all `destructive=exec severity from pMan[`ops] where op=`manual];
chk["manual carries originating change"; all `typeChange`listChange`kindChange`partitionChange in exec change from pMan[`ops] where op=`manual];
chk["manual detail mentions recreate"; all (exec detail from pMan[`ops] where op=`manual) like "*drop-and-recreate*"];

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

-1 "--- plan: end-to-end against a temp HDB ---";
HDB:`:testhdb_plan;
/ build a splayed `inst on disk: sym (no attr), name
system "mkdir ",ssr[1_string ` sv HDB,`inst,`; "/"; "\\"];
(` sv HDB,`inst,`sym)  set `AA`BB;
(` sv HDB,`inst,`name) set `x`y;
(` sv HDB,`inst,`.d)   set `sym`name;
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

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
