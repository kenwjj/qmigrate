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

-1"--- apply: backup / restore / delete-created ---";
rmrf "testhdb_bk"; B:`:testhdb_bk; bd:` sv B,`t;
(` sv bd,`a) set 1 2 3;
(` sv bd,`.d) set enlist `a;
bdir:.qm.i.backupDir[B; ()!()];
chk["backupDir default"; bdir~` sv B,`.qmbackup];
oa:` sv bd,`a;
.qm.i.doBackup[bdir; enlist oa];
oa set 9 9 9;                                  / mutate
.qm.i.restore[bdir; enlist oa];
chk["restore round-trip"; (get oa)~1 2 3];
/ create + delete a nested tree, deepest-first
nf:` sv B,`p,`t,`x;
nf set 1 2;
.qm.i.deleteCreated (nf; ` sv B,`p,`t; ` sv B,`p);
chk["deleteCreated removed file"; not `x in key ` sv B,`p,`t];
chk["deleteCreated removed dirs"; not `p in key B];
rmrf "testhdb_bk";

-1"--- apply: gate / noop / dryRun / setAttr e2e ---";
rmrf "testhdb_s"; S:`:testhdb_s; ssd:` sv S,`inst;
(` sv ssd,`sym)  set `AA`BB`CC;            / already sorted -> `s satisfiable
(` sv ssd,`name) set `x`y`z;
(` sv ssd,`.d)   set `sym`name;
/ declared: set `s on sym (setAttr), everything else matches
dinst:.qm.schema[`inst] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`s]; .qm.col[`name;`symbol]);
dr:.qm.diff[S; (enlist`inst)!enlist dinst; ()!()];
pl:.qm.plan[dr; (enlist`inst)!enlist dinst];
/ dryRun first: no writes
resDry:.qm.apply[S; pl; (enlist`dryRun)!enlist 1b];
chk["dryRun status";   resDry[`status]~`dryRun];
chk["dryRun planned";  `planned in resDry[`ops]`status];
chk["dryRun no attr";  `~attr get ` sv ssd,`sym];
/ real apply
res:.qm.apply[S; pl; ()!()];
chk["setAttr applied";  res[`status]~`applied];
chk["sym has s attr";   `s=attr get ` sv ssd,`sym];
chk["report has done";  `done in res[`ops]`status];
/ noop: re-apply same plan against the now-matching HDB
dr2:.qm.diff[S; (enlist`inst)!enlist dinst; ()!()];
pl2:.qm.plan[dr2; (enlist`inst)!enlist dinst];
res2:.qm.apply[S; pl2; ()!()];
chk["noop status"; res2[`status]~`noop];
/ gate: a destructive plan is blocked
ddrp:.qm.schema[`inst] (.qm.splayed[]; .qm.colx[`sym;`symbol;`attr`s]);   / drops `name
plD:.qm.plan[.qm.diff[S;(enlist`inst)!enlist ddrp;()!()]; (enlist`inst)!enlist ddrp];
resB:.qm.apply[S; plD; ()!()];
chk["blocked status";   resB[`status]~`blocked];
chk["blocked no write"; `name in get ` sv ssd,`.d];
chk["bad opts throws";  thr[.qm.apply[S;pl;]; (enlist`bogus)!enlist 1]];
chk["malformed plan throws"; thr[.qm.apply[S; (enlist`bogus)!enlist 1;]; ()!()]];
rmrf "testhdb_s";

-1"--- apply: addColumn (literal / list / typed-null) ---";
rmrf "testhdb_ac"; AC:`:testhdb_ac; acd:` sv AC,`t;
(` sv acd,`k) set 1 2 3;
(` sv acd,`.d) set enlist `k;
dac:.qm.schema[`t] (
  .qm.splayed[];
  .qm.col [`k;     `long];
  .qm.colx[`flag;  `boolean; (enlist`default)!enlist 1b];   / literal default
  .qm.colx[`tags;  `symbol;  `default`list!(enlist`x;1b)];   / list col, list-valued default per cell
  .qm.col [`note;  `symbol] );                                / no default -> typed null
plac:.qm.plan[.qm.diff[AC;(enlist`t)!enlist dac;()!()]; (enlist`t)!enlist dac];
resac:.qm.apply[AC; plac; ()!()];
chk["addColumn applied";   resac[`status]~`applied];
chk["literal default";     (get ` sv acd,`flag)~3#1b];
chk["list default cell";   (get ` sv acd,`tags)~3#enlist enlist `x];
chk["typed-null default";  (get ` sv acd,`note)~3#`];
chk["all in .d";           (get ` sv acd,`.d)~`k`flag`tags`note];
chk["re-diff ok";          `ok~(.qm.diff[AC;(enlist`t)!enlist dac;()!()])`maxSeverity];
rmrf "testhdb_ac";

-1"--- apply: addColumn defaultFn + preflight throws ---";
rmrf "testhdb_fn"; FN:`:testhdb_fn; fnd:` sv FN,`t;
(` sv fnd,`a) set 10 20 30;
(` sv fnd,`.d) set enlist `a;
.user.mk:{[path;col] count[get ` sv path,`a]#42};      / returns a length-n long vector
dfn:.qm.schema[`t] (.qm.splayed[]; .qm.col[`a;`long]; .qm.colx[`b;`long;`defaultFn`.user.mk]);
plfn:.qm.plan[.qm.diff[FN;(enlist`t)!enlist dfn;()!()]; (enlist`t)!enlist dfn];
resfn:.qm.apply[FN; plfn; ()!()];
chk["defaultFn applied"; resfn[`status]~`applied];
chk["defaultFn values";  (get ` sv fnd,`b)~3#42];
/ missing defaultFn -> preflight throws, nothing created
/ use a fresh HDB (only col a) so the plan is applyable (no destructive drop)
rmrf "testhdb_bad"; FNB:`:testhdb_bad; fnbd:` sv FNB,`t;
(` sv fnbd,`a) set 10 20 30;
(` sv fnbd,`.d) set enlist `a;
dbad:.qm.schema[`t] (.qm.splayed[]; .qm.col[`a;`long]; .qm.colx[`c;`long;`defaultFn`.user.nope]);
plbad:.qm.plan[.qm.diff[FNB;(enlist`t)!enlist dbad;()!()]; (enlist`t)!enlist dbad];
chk["missing defaultFn throws"; thr[.qm.apply[FNB;plbad;]; ()!()]];
chk["throw left no col c";      not `c in get ` sv fnbd,`.d];
rmrf "testhdb_bad";
rmrf "testhdb_fn";
/ unsatisfiable attribute -> preflight throws, nothing marked
rmrf "testhdb_at"; AT:`:testhdb_at; atd:` sv AT,`t;
(` sv atd,`u) set 1 1 2;                               / dups -> cannot be `u
(` sv atd,`.d) set enlist `u;
dat:.qm.schema[`t] (.qm.splayed[]; .qm.colx[`u;`long;`attr`u]);    / declared `u -> setAttr
plat:.qm.plan[.qm.diff[AT;(enlist`t)!enlist dat;()!()]; (enlist`t)!enlist dat];
chk["unsatisfiable attr throws"; thr[.qm.apply[AT;plat;]; ()!()]];
chk["attr-throw left col unmarked"; `~attr get ` sv atd,`u];
rmrf "testhdb_at";

-1"--- apply: dropColumn (destructive, allowDestructive) ---";
rmrf "testhdb_dc"; DC:`:testhdb_dc; dcd:` sv DC,`t;
(` sv dcd,`keep) set 1 2 3;
(` sv dcd,`gone) set `a`b`c;
(` sv dcd,`.d)   set `keep`gone;
ddc:.qm.schema[`t] (.qm.splayed[]; .qm.col[`keep;`long]);     / `gone not declared -> drop
/ destructive: must opt in at the differ for the plan to be applyable
pldc:.qm.plan[.qm.diff[DC;(enlist`t)!enlist ddc;(enlist`allowDestructive)!enlist 1b]; (enlist`t)!enlist ddc];
resdc:.qm.apply[DC; pldc; ()!()];
chk["dropColumn applied"; resdc[`status]~`applied];
chk["gone removed from .d"; (get ` sv dcd,`.d)~enlist `keep];
chk["gone file deleted";    not `gone in key dcd];
chk["re-diff ok";           `ok~(.qm.diff[DC;(enlist`t)!enlist ddc;()!()])`maxSeverity];
rmrf "testhdb_dc";

-1"--- apply: clearAttr ---";
rmrf "testhdb_ca"; CA:`:testhdb_ca; cad:` sv CA,`t;
(` sv cad,`g) set `g#`a`b`c;                  / on-disk has `g attr
(` sv cad,`.d) set enlist `g;
dca:.qm.schema[`t] (.qm.splayed[]; .qm.col[`g;`symbol]);    / declared: no attr -> clearAttr
plca:.qm.plan[.qm.diff[CA;(enlist`t)!enlist dca;()!()]; (enlist`t)!enlist dca];
resca:.qm.apply[CA; plca; ()!()];
chk["clearAttr applied"; resca[`status]~`applied];
chk["attr cleared";      `~attr get ` sv cad,`g];
rmrf "testhdb_ca";

-1"--- apply: reorderColumns ---";
rmrf "testhdb_ro"; RO:`:testhdb_ro; rod:` sv RO,`t;
(` sv rod,`a) set 1 2 3;
(` sv rod,`b) set 4 5 6;
(` sv rod,`.d) set `b`a;                       / on-disk order b,a
dro:.qm.schema[`t] (.qm.splayed[]; .qm.col[`a;`long]; .qm.col[`b;`long]);   / declared a,b
plro:.qm.plan[.qm.diff[RO;(enlist`t)!enlist dro;()!()]; (enlist`t)!enlist dro];
resro:.qm.apply[RO; plro; ()!()];
chk["reorder applied"; resro[`status]~`applied];
chk[".d reordered";    (get ` sv rod,`.d)~`a`b];
chk["data intact";     (get ` sv rod,`a)~1 2 3];
chk["re-diff ok";      `ok~(.qm.diff[RO;(enlist`t)!enlist dro;()!()])`maxSeverity];
rmrf "testhdb_ro";

-1"";
-1"RESULT  ok=",string[ok]," fail=",string fail;
exit fail
