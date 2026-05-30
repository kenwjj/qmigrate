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

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
