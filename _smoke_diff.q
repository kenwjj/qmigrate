/ Manual smoke check for the .qm differ (not a test framework — see memory).
/ Run: QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke_diff.q -q

\l src/qm.q
\l src/diff.q

ok:0; fail:0;
chk:{[d;c] $[c; [ok+:1; -1 "  ok   ",d]; [fail+:1; -1 "  FAIL ",d]] };
thr:{[f;a] 1b~@[f;a;{[e]1b}] };               / true if f[a] signals

-1 "--- scaffold ---";
chk["diff.q loaded"; `sevRank in key `.qm.i];

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
