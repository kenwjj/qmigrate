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

/ comparison helpers — filled in later tasks; return an empty rows table for now
i.cmpCols:{[declared;actual] i.noRows };
i.cmpTable:{[declared;actual] i.noRows };
i.cmpEnum:{[declared;actual] i.noRows };

/ compare two section-6 reps. actual is (::) when the table is absent on disk.
i.compare:{[declared;actual]
  nm:declared`name;
  if[(::)~actual; :i.row[nm;`;`newTable;::;declared`kind;"table not present on disk"]];
  raze (i.cmpTable[declared;actual]; i.cmpCols[declared;actual]; i.cmpEnum[declared;actual]) };

\d .
