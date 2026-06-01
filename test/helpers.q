/ Shared test helpers, loaded globally by test/run.q before .qu.runTestFolder.
/ Defined as globals so before/expect/after blocks in every .quke can use them.

/ thr[f;a] -> 1b iff f[a] signals (expect-throws)
thr:{[f;a] 1b~@[f;a;{[e]1b}] };

/ rmrf[d] -> recursively delete dir d, tolerant of absence (traps 'os).
/ d passed in explicitly: a q lambda's free vars resolve to globals, not the
/ enclosing local, so the naive form silently no-ops. See _smoke_apply.q note.
rmrf:{[d] @[{[d] system $[.z.o like "w*";"rmdir /s /q ",ssr[d;"/";"\\"];"rm -rf ",d]}; d; {}] };

/ mkcols / mkrep: build a section-6 columns table / table report for differ tests.
/ Param names avoid q reserved words (type,list,attr,cols,names).
mkcols:{[nms;typs;lsts;atts;enms]
  flip `name`type`list`attr`default`defaultFn`enum!(
    nms; typs; lsts; atts; count[nms]#(::); count[nms]#`; enms) };
mkrep:{[nm;kind;pf;c] `name`kind`partitionField`columns!(nm;kind;pf;c) };
