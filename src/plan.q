/ qmigrate — plan layer (Phase 1)
/ Spec: docs/superpowers/specs/2026-05-31-plan-layer-design.md
//
/ Consumes a differ result (.qm.diff output) + the declared schemas and
/ produces an ordered, pure migration plan. No disk I/O.
/ Public: .qm.plan        Pure helpers: .qm.i.opFor .qm.i.orderOps

\d .qm

/ empty ops table (correct column types; seq filled by orderOps).
/ flip (not ([]...)) because `params holds dict cells and `detail holds strings.
i.noOps:0#flip `seq`table`column`op`change`severity`detail`params!(
  `long$(); `$(); `$(); `$(); `$(); `$(); (); ());

/ build a 1-row op table
i.op:{[tbl;col;op;chg;sev;det;prm]
  flip `seq`table`column`op`change`severity`detail`params!(
    enlist 0N; enlist tbl; enlist col; enlist op; enlist chg; enlist sev; enlist det; enlist prm) };

/ pull a declared column's full spec out of a section-6 columns table
i.declCol:{[ct;c]
  idx:first where ct[`name]=c;
  `type`list`attr`default`defaultFn!(
    ct[`type]idx; ct[`list]idx; ct[`attr]idx; ct[`default]idx; ct[`defaultFn]idx) };

/ map one differ row -> 0+ plan op rows. decl is the table's schema dict, or (::) if undeclared.
i.opFor:{[decl;row]
  chg:row`change; tbl:row`table; col:row`column; sev:row`severity;
  $[chg~`newTable;
      i.op[tbl;`;`createTable;chg;sev;
           "create ",string[decl`kind]," table ",string tbl;
           `kind`partitionField`columns!(decl`kind; decl`partitionField; decl`columns)];
    / unmanagedTable, skipped, unknown -> no op
    i.noOps ] };

/ intra-table op precedence (spec section 4)
i.opRank:`createTable`addColumn`dropColumn`setAttr`clearAttr`reEnumerate`reorderColumns`manual!til 8;

/ stable-order ops by (table first-appearance, op precedence); assign seq 1..n
i.orderOps:{[ops]
  if[0=count ops; :ops];
  bad:distinct ops[`op] except key i.opRank;
  if[count bad; '"qm: orderOps: unknown op(s): ",", " sv string bad];
  ti:(distinct ops`table)?ops`table;          / table first-appearance index
  / multiplier 100 is safe: opRank is 0-7, so the max intra-table key (7) never
  / reaches the next table's base (100), keeping inter-table order intact.
  ops:ops iasc (100*ti)+i.opRank ops`op;
  update seq:`long$1+til count ops from ops };

/ public: build a migration plan from a differ result + declared schemas
plan:{[dr;dd]
  if[not all `maxSeverity`applyable`rows in key dr;
     '"qm: plan: malformed differ result"];
  if[not 99h=type dd; '"qm: plan: declaredDict must be a dict"];
  rows:dr`rows;
  declFor:{[dd;t] $[t in key dd; dd t; ::]};
  ops:i.orderOps raze enlist[i.noOps],
        {[dd;declFor;r] i.opFor[declFor[dd;r`table]; r]}[dd;declFor] each rows;
  `maxSeverity`applyable`ops!(dr`maxSeverity; dr`applyable; ops) };

\d .
