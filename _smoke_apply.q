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
