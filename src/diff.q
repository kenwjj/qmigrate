/ qmigrate — differ layer (Phase 1)
/ Spec: docs/superpowers/specs/2026-05-30-differ-design.md
//
/ Compares a declared schema (section-6 rep) against an on-disk HDB.
/ Public (read disk): .qm.diff .qm.diffTable
/ Pure core:          .qm.i.compare .qm.i.rollupWith

\d .qm

/ severity ordering (low -> high)
i.sevRank:`ok`change`warning`destructive!0 1 2 3;

/ change-type -> severity (spec section 4)
i.changeSev:(`newTable`unmanagedTable`addColumn`attrChange`colOrderChange`dropColumn`typeChange`listChange`kindChange`partitionChange`enumMismatch`skipped)!
            `change`warning`change`change`change`destructive`destructive`destructive`destructive`destructive`warning`ok;

/ build a 1-row diff table. flip (not ([]...)) because `from is reserved.
i.row:{[tbl;col;chg;frm;t;det]
  if[null i.changeSev chg; '"qm: unknown change type: ",string chg];
  flip `table`column`change`from`to`severity`detail!(
    enlist tbl; enlist col; enlist chg; enlist frm; enlist t; enlist i.changeSev chg; enlist det) };

/ empty rows table with the right columns
i.noRows:0#i.row[`;`;`skipped;::;::;""];

/ pull one column's fields out of a columns table as a dict
i.colInfo:{[ct;c]
  idx:first where ct[`name]=c;
  `type`list`attr`enum!(ct[`type]idx; ct[`list]idx; ct[`attr]idx; $[`enum in cols ct; ct[`enum]idx; 0b]) };

/ add / drop / type / list / attr  (spec section 4)
i.cmpCols:{[declared;actual]
  nm:declared`name;
  dc:declared`columns; ac:actual`columns;
  dn:dc`name; an:ac`name;
  adds:dn except an;
  drops:an except dn;
  common:dn inter an;
  rows:i.noRows;
  rows:rows,raze enlist[i.noRows],{[nm;dc;c] i.row[nm;c;`addColumn;::;(i.colInfo[dc;c])`type;"declared, absent on disk"]}[nm;dc] each adds;
  rows:rows,raze enlist[i.noRows],{[nm;ac;c] i.row[nm;c;`dropColumn;(i.colInfo[ac;c])`type;::;"on disk, not declared"]}[nm;ac] each drops;
  rows:rows,raze enlist[i.noRows],{[nm;dc;ac;c]
    di:i.colInfo[dc;c]; ai:i.colInfo[ac;c];
    r:i.noRows;
    if[not di[`type]~ai`type; r:r,i.row[nm;c;`typeChange;ai`type;di`type;"type differs"]];
    if[not di[`list]~ai`list; r:r,i.row[nm;c;`listChange;ai`list;di`list;"list-ness differs"]];
    if[not di[`attr]~ai`attr; r:r,i.row[nm;c;`attrChange;ai`attr;di`attr;"attribute differs"]];
    r }[nm;dc;ac] each common;
  rows };
i.cmpTable:{[declared;actual]
  nm:declared`name;
  rows:i.noRows;
  if[not declared[`kind]~actual`kind;
     rows:rows,i.row[nm;`;`kindChange;actual`kind;declared`kind;"table kind differs"]];
  if[(declared[`kind]~`partitioned) & (actual[`kind]~`partitioned) & not declared[`partitionField]~actual`partitionField;
     rows:rows,i.row[nm;`;`partitionChange;actual`partitionField;declared`partitionField;"partition field differs"]];
  dn:declared[`columns]`name; an:actual[`columns]`name;
  common:dn inter an;
  dco:dn where dn in common;     / declared relative order of common cols
  aco:an where an in common;     / on-disk relative order of common cols
  if[not dco~aco;
     rows:rows,i.row[nm;`;`colOrderChange;aco;dco;"common columns in different order"]];
  rows };

/ enumeration mismatch (spec section 9): partitioned symbol cols are enum-by-default
i.cmpEnum:{[declared;actual]
  nm:declared`name;
  dc:declared`columns; ac:actual`columns;
  common:(dc`name) inter ac`name;
  declEnum:declared[`kind]~`partitioned;
  raze enlist[i.noRows],{[nm;dc;ac;declEnum;c]
    di:i.colInfo[dc;c]; ai:i.colInfo[ac;c];
    if[not di[`type]~`symbol; :i.noRows];
    if[declEnum~ai`enum; :i.noRows];
    i.row[nm;c;`enumMismatch;ai`enum;declEnum;"enumeration state differs"]
   }[nm;dc;ac;declEnum] each common };

/ compare two section-6 reps. actual is (::) when the table is absent on disk.
i.compare:{[declared;actual]
  nm:declared`name;
  if[(::)~actual; :i.row[nm;`;`newTable;::;declared`kind;"table not present on disk"]];
  raze (i.cmpTable[declared;actual]; i.cmpCols[declared;actual]; i.cmpEnum[declared;actual]) };

/ validate + default the opts dict (spec section 6). only allowDestructive is recognised.
i.normOpts:{[opts]
  bad:key[opts] except enlist `allowDestructive;
  if[count bad; '"qm: unknown diff option(s): ",", " sv string bad];
  (enlist `allowDestructive)!enlist $[`allowDestructive in key opts; opts`allowDestructive; 0b] };

/ roll a rows table up into the result dict, given normalised opts
i.rollupWith:{[rows;o]
  ms:$[count rows; key[i.sevRank] max i.sevRank rows`severity; `ok];
  hasD:`destructive in rows`severity;
  ap:(not hasD) | o`allowDestructive;
  `maxSeverity`applyable`rows!(ms;ap;rows) };

/ lowercase meta type char -> section-4 type symbol
i.charType:"bxhijefcspmdznuvtg"!`boolean`byte`short`int`long`real`float`char`symbol`timestamp`month`date`datetime`timespan`minute`second`time`guid;

/ meta type char -> (type symbol; list flag). uppercase => vector column; " " => string.
i.colType:{[ch]
  if[ch=" "; :(`string;0b)];
  lc:lower ch;
  if[not lc in key i.charType; '"qm: unknown on-disk type char '",ch,"'"];
  (i.charType lc; not ch=lc) };

/ infer the partition field name from partition dir-name format
i.partField:{[partDirs]
  s:string first partDirs;
  $[s like "[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]"; `date;
    s like "[0-9][0-9][0-9][0-9].[0-9][0-9]"; `month;
    s like "[0-9][0-9][0-9][0-9]"; `year;
    `int] };

/ detect if a column file is enumerated: raw type 20-76 = enum domain
i.isEnum:{[dir;c] (type get ` sv dir,c) within 20 76};

/ read a splayed/partition table dir into an actual rep (section-6 + enum column)
i.readDir:{[dir;name;kind;pf]
  m:0!meta get dir;
  ct:i.colType each m`t;                       / list of (type;listFlag)
  colTab:flip `name`type`list`attr`default`defaultFn`enum!(
    m`c; ct[;0]; ct[;1]; m`a; count[m`c]#(::); count[m`c]#`; i.isEnum[dir] each m`c);
  `name`kind`partitionField`columns!(name; kind; pf; colTab) };

/ introspect one on-disk table -> actual rep, or (::) if absent
i.introspect:{[root;table]
  / map the HDB's enum domain so enumerated symbol columns resolve to `s with f=`sym.
  / required when diffing an HDB the current session did not itself build.
  if[`sym in key root; `sym set get ` sv root,`sym];
  sdir:` sv root,table;
  if[`.d in key sdir; :i.readDir[sdir; table; `splayed; `]];   / splayed
  ents:key root;
  isPart:{[root;table;e] `.d in key ` sv root,e,table}[root;table] each ents;
  partDirs:ents where isPart;
  if[count partDirs;
     latest:last asc partDirs;
     :i.readDir[` sv root,latest,table; table; `partitioned; i.partField partDirs] ];
  (::) };

/ rows for one declared table (memory -> skipped; else introspect + compare)
i.tableRows:{[root;declared]
  if[declared[`kind]~`memory;
     :i.row[declared`name;`;`skipped;::;::;"in-memory table; no disk target"]];
  i.compare[declared; i.introspect[root;declared`name]] };

/ public: diff one declared table against the HDB
diffTable:{[root;declared;opts]
  o:i.normOpts opts;
  if[not 11h=type key root; '"qm: hdb path not found or not a directory: ",string root];
  i.rollupWith[i.tableRows[root;declared]; o] };

\d .
