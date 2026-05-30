/ Manual smoke check for the .qm differ (not a test framework — see memory).
/ Run: QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q

\l src/qm.q
\l src/diff.q

ok:0; fail:0;
chk:{[d;c] $[c; [ok+:1; -1 "  ok   ",d]; [fail+:1; -1 "  FAIL ",d]] };
thr:{[f;a] 1b~@[f;a;{[e]1b}] };               / true if f[a] signals

-1 "--- compare: newTable ---";
d:.qm.schema[`trade] (.qm.partitioned[`date]; .qm.col[`a;`long]);
r:.qm.i.compare[d; ::];
chk["newTable 1 row";      1=count r];
chk["newTable change";     (first r)[`change]~`newTable];
chk["newTable severity";   (first r)[`severity]~`change];
chk["newTable to=kind";    (first r)[`to]~`partitioned];

-1 "--- compare: columns ---";
/ helper to build a section-6 columns table (with enum) for tests
/ Note: param names avoid q reserved words (type,list,attr,cols,names etc.)
mkcols:{[nms;typs;lsts;atts;enms]
  flip `name`type`list`attr`default`defaultFn`enum!(
    nms; typs; lsts; atts; count[nms]#(::); count[nms]#`; enms) };
mkrep:{[nm;kind;pf;c] `name`kind`partitionField`columns!(nm;kind;pf;c) };

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

-1 "--- compare: table-level ---";
/ kindChange: declared partitioned, actual splayed
dk:mkrep[`t;`partitioned;`date] mkcols[enlist`a; enlist`long; enlist 0b; enlist`; enlist 0b];
ak:mkrep[`t;`splayed;`]          mkcols[enlist`a; enlist`long; enlist 0b; enlist`; enlist 0b];
rk:.qm.i.cmpTable[dk;ak];
chk["kindChange";     `kindChange in exec change from rk];
chk["kindChange sev"; `destructive in exec severity from rk where change=`kindChange];
chk["kind change -> no partitionChange"; 0=count select from rk where change=`partitionChange];

/ partitionChange: date vs month
dp:mkrep[`t;`partitioned;`date]  mkcols[enlist`a; enlist`long; enlist 0b; enlist`; enlist 0b];
ap2:mkrep[`t;`partitioned;`month] mkcols[enlist`a; enlist`long; enlist 0b; enlist`; enlist 0b];
chk["partitionChange"; `partitionChange in exec change from .qm.i.cmpTable[dp;ap2]];

/ colOrderChange: same cols, different order
dord:mkrep[`t;`splayed;`] mkcols[`a`b; `long`long; 00b; ``; 00b];
aord:mkrep[`t;`splayed;`] mkcols[`b`a; `long`long; 00b; ``; 00b];
chk["colOrderChange";     `colOrderChange in exec change from .qm.i.cmpTable[dord;aord]];
chk["colOrderChange sev"; `change in exec severity from .qm.i.cmpTable[dord;aord] where change=`colOrderChange];

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

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
