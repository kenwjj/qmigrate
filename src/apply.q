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

/ ---------------------------------------------------------------------------
/ backup sidecar (flatten each backed-up path to one flat name under the dir)
/ ---------------------------------------------------------------------------
i.backupDir:{[root;opts] $[`backupDir in key opts; opts`backupDir; ` sv root,`.qmbackup]};
i.bkey:{[bdir;p] ` sv bdir,`$ssr[1_string p;"/";"_"]};
i.symExists:{[root] `sym in key root};

i.doBackup:{[bdir;bpaths] {[bdir;p] (i.bkey[bdir;p]) set get p}[bdir] each bpaths;};
i.restore :{[bdir;bpaths] {[bdir;p] p set get i.bkey[bdir;p]}[bdir] each bpaths;};
i.deleteCreated:{[cpaths]
  / deepest-first by slash count, so files go before their dirs
  ord:idesc {sum "/"=x} each 1_'string cpaths;
  {hdel x} each cpaths ord; };

/ ---------------------------------------------------------------------------
/ options
/ ---------------------------------------------------------------------------
i.normApplyOpts:{[opts]
  if[not 99h=type opts; '"qm: apply: opts must be a dict"];
  bad:key[opts] except `dryRun`backupDir;
  if[count bad; '"qm: apply: unknown option(s): ",", " sv string bad];
  opts };

/ ---------------------------------------------------------------------------
/ per-dir resolved fill for addColumn (raw symbols, pre-enumeration)
/ ---------------------------------------------------------------------------
i.fillFor:{[dir;ci]
  n:i.rowCount dir;
  $[not ci[`defaultFn]~`;
      [f:@[get;ci`defaultFn;{[s;e]'"qm: apply: defaultFn not defined: ",string s}[ci`defaultFn]];
       v:f[dir;`col]; if[not n=count v; '"qm: apply: defaultFn returned wrong length"]; v];
    not ci[`default]~(::);
      $[ci`list; n#enlist ci`default; n#ci`default];
    / neither default nor defaultFn -> typed null (scalar) / empty typed list (list col)
    $[ci`list; n#enlist 0#first i.tnull ci`type; n#first i.tnull ci`type] ] };

/ ---------------------------------------------------------------------------
/ build + validate one entry from a plan op row (READ-ONLY; throws on bad input)
/ ---------------------------------------------------------------------------
i.entry:{[root;r]
  op:r`op; tbl:r`table; col:r`column;
  base:`op`seq`table`column`severity`detail`params!(op;r`seq;tbl;col;r`severity;r`detail;r`params);
  $[op~`createTable;
      base,`kind`pf`colz`dirs`isPart`fillv!(r[`params]`kind;r[`params]`partitionField;r[`params]`columns;();(r[`params]`kind)~`partitioned;()!());
    op in `addColumn`dropColumn`setAttr`clearAttr`reorderColumns`reEnumerate;
      [dirs:i.partDirs[root;tbl]; isPart:`partitioned~i.kindOf[root;tbl];
       fillv:$[op~`addColumn; dirs!i.fillFor[;r`params] each dirs; ()!()];
       / validation (fail before touching data)
       if[op~`addColumn; {[a;v] if[not i.attrOK[a;v]; '"qm: apply: new column data does not satisfy attr"]}[r[`params]`attr;] each value fillv];
       if[op~`setAttr;   {[d;col;a] if[not i.attrOK[a;get i.dpath[d;col]]; '"qm: apply: on-disk data does not satisfy attr ",string a]}[;col;r[`params]`attr] each dirs];
       base,`dirs`isPart`fillv!(dirs;isPart;fillv)];
    base ] };   / manual etc — kept for the report, never run

/ ---------------------------------------------------------------------------
/ per-op FILE TARGETS (pure) -> `backup`create!(backupPaths;createPaths)
/ ---------------------------------------------------------------------------
i.opTargets:{[root;e]
  op:e`op; tbl:e`table; col:e`column; dirs:e`dirs;
  symp:` sv root,`sym;
  symBC:$[i.symExists root; (enlist symp;()); ((); enlist symp)];   / sym: (backup; create)
  $[op~`addColumn;
      [b:i.dpath[;`.d] each dirs; c:i.dpath[;col] each dirs;
       if[e`isPart; if[(e[`params]`type)~`symbol; b,:symBC 0; c,:symBC 1]];
       `backup`create!(b;c)];
    op~`dropColumn;
      `backup`create!((i.dpath[;col] each dirs),i.dpath[;`.d] each dirs; ());
    op~`reorderColumns;
      `backup`create!(i.dpath[;`.d] each dirs; ());
    op~`reEnumerate;
      `backup`create!((i.dpath[;col] each dirs),symBC 0; symBC 1);
    op in `setAttr`clearAttr;
      `backup`create!(i.dpath[;col] each dirs; ());
    `backup`create!(();()) ] };

/ ---------------------------------------------------------------------------
/ per-op RUN (writes). Each branch fans out across e`dirs.
/ ---------------------------------------------------------------------------
i.runOp:{[root;e]
  op:e`op; tbl:e`table; col:e`column; dirs:e`dirs;
  $[op~`addColumn;
      {[root;e;dir]
        ci:e`params; v:e[`fillv]dir;
        v:$[e[`isPart]&(ci`type)~`symbol; i.enum[root;v]; v];   / enumerate if partitioned symbol
        v:$[(ci`attr)~`; v; (ci`attr)#v];                        / apply declared attr
        (i.dpath[dir;e`column]) set v;
        (i.dpath[dir;`.d]) set (i.getD dir),e`column }[root;e] each dirs;
    op~`dropColumn;
      {[col;dir] hdel i.dpath[dir;col]; (i.dpath[dir;`.d]) set (i.getD dir)except col}[col] each dirs;
    op~`clearAttr;
      {[col;dir] p:i.dpath[dir;col]; p set `#get p}[col] each dirs;
    op~`reorderColumns;
      {[ord;dir] (i.dpath[dir;`.d]) set ord}[e[`params]`order] each dirs;
    op~`reEnumerate;
      {[root;col;dir] p:i.dpath[dir;col]; p set i.enum[root; get p]}[root;col] each dirs;
    op~`setAttr;
      {[col;a;dir] p:i.dpath[dir;col]; p set a#get p}[col;e[`params]`attr] each dirs;
    '"qm: apply: unknown op ",string op ] };

/ ---------------------------------------------------------------------------
/ preflight (READ-ONLY): build entries, aggregate backup/create sets
/ ---------------------------------------------------------------------------
i.preflight:{[root;planResult;opts]
  if[not all `applyable`ops in key planResult; '"qm: apply: malformed plan result"];
  ops:planResult`ops;
  exrows:select from ops where not op=`manual;
  entries:i.entry[root;] each exrows;          / validates; may throw
  tgts:i.opTargets[root;] each entries;
  `entries`backup`create!(entries; raze tgts@\:`backup; raze tgts@\:`create) };

/ ---------------------------------------------------------------------------
/ execute: back up -> run in seq order -> rollback (restore + delete) on fail
/ ---------------------------------------------------------------------------
i.execute:{[root;wl;opts]
  bdir:i.backupDir[root;opts];
  es:wl`entries;
  i.doBackup[bdir; distinct wl`backup];
  failIdx:0N; i:0; n:count es;
  while[(i<n)&null failIdx;
    runok:1b~.[{[root;e] i.runOp[root;e]; 1b};(root;es i);{[e]0b}];
    $[runok; i+:1; failIdx:i] ];
  $[null failIdx;
    `status`failIdx`backup!(`applied; 0N; bdir);
    [i.restore[bdir; distinct wl`backup]; i.deleteCreated wl`create;
     `status`failIdx`backup!(`rolledBack; failIdx; bdir)] ] };

/ ---------------------------------------------------------------------------
/ report: full plan ops + a status column keyed by seq
/ ---------------------------------------------------------------------------
i.report:{[ops;statusBySeq]
  flip `seq`table`column`op`severity`status`detail!(
    ops`seq; ops`table; ops`column; ops`op; ops`severity;
    statusBySeq ops`seq; ops`detail) };

/ ---------------------------------------------------------------------------
/ public: execute a plan result against the HDB
/ ---------------------------------------------------------------------------
apply:{[root;planResult;opts]
  if[not 11h=type key root; '"qm: apply: hdb path not found: ",string root];
  o:i.normApplyOpts opts;
  if[not all `applyable`ops in key planResult; '"qm: apply: malformed plan result"];
  ops:planResult`ops;
  / gate: refuse a non-applyable plan
  if[not planResult`applyable;
     :`status`ops`backup!(`blocked; i.report[ops; (exec seq from ops)!count[ops]#`skipped]; `)];
  exrows:select from ops where not op=`manual;
  if[0=count exrows;
     :`status`ops`backup!(`noop; i.report[ops; (exec seq from ops)!count[ops]#`skipped]; `)];
  wl:i.preflight[root;planResult;o];
  if[$[`dryRun in key o; o`dryRun; 0b];
     sd:(exec seq from ops)!count[ops]#`skipped;
     sd[exrows`seq]:`planned;
     :`status`ops`backup!(`dryRun; i.report[ops;sd]; `)];
  r:i.execute[root;wl;o];
  exseq:exrows`seq;
  sd:(exec seq from ops)!count[ops]#`skipped;
  $[r[`status]~`applied;
     sd[exseq]:`done;
     [sd[exseq]:`rolledBack; sd[exseq r`failIdx]:`failed] ];
  `status`ops`backup!(r`status; i.report[ops;sd]; r`backup) };

\d .
