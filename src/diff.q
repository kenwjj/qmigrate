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
  i:first where ct[`name]=c;
  `type`list`attr`enum!(ct[`type]i; ct[`list]i; ct[`attr]i; $[`enum in cols ct; ct[`enum]i; 0b]) };

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
i.cmpTable:{[declared;actual] i.noRows };
i.cmpEnum:{[declared;actual] i.noRows };

/ compare two section-6 reps. actual is (::) when the table is absent on disk.
i.compare:{[declared;actual]
  nm:declared`name;
  if[(::)~actual; :i.row[nm;`;`newTable;::;declared`kind;"table not present on disk"]];
  raze (i.cmpTable[declared;actual]; i.cmpCols[declared;actual]; i.cmpEnum[declared;actual]) };

\d .
