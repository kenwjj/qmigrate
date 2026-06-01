/ qcumber runner. Run from the repo root:  q test/run.q -q
/ Loads the vendored qcumber + the project under test + test helpers, runs every
/ *.quke under test/, and exits non-zero on any failed expectation or parse error.
/ Space-in-path: an absolute \l with a space throws 'nyi, and qcumber's AX loader
/ uses \l on AXLIBRARIES_HOME internally, so that path must be space-free too. On
/ Windows we resolve the 8.3 short path; repo-internal files load via relative paths.
/ (Note: no bare "/" comment lines below -- q reads a lone "/" as a multiline-comment
/ opener and would swallow the rest of the script.)

root:ssr[{r:system x;$[10h=type r;r;first r]}$[.z.o like "w*";"cd";"pwd"];"\\";"/"];

/ Windows: 8.3 short path of a (possibly space-containing) path, via a temp bat.
/ Kept on ONE line: q's multi-line script continuation mis-parses a split definition.
shortPath:{[lp] bat:ssr[getenv[`TEMP];"\\";"/"],"/__gsp.bat"; hsym[`$bat] 0: enlist "@echo off\r\nfor %%i in (\"",ssr[lp;"/";"\\"],"\") do echo %%~si"; r:system ssr[bat;"/";"\\"]; @[system;"del \"",ssr[bat;"/";"\\"],"\"";{}]; ssr[$[0h=type r;first r;r];"\\";"/"]};

ax:$[.z.o like "w*"; shortPath[root,"/lib/ax"]; root,"/lib/ax"];
psep:$[.z.o like "w*"; ";"; ":"];
`AXLIBRARIES_HOME setenv ax;
`PATH setenv (ax,"/ws/lib"),psep,getenv`PATH;

/ project under test, in dependency order (relative paths -> no spaces)
system "l src/qm.q";
system "l src/diff.q";
system "l src/plan.q";
system "l src/apply.q";
system "l test/helpers.q";

/ qcumber entry (relative path -> no spaces)
system "l lib/ax/ws/qcumber.q_";

r:.qu.runTestFolder `:test;
nTot :count r`allTestResults;
nFail:count r`allFailedTestResults;
nPE  :count r`parseErrorList;
-1 "qcumber: TOTAL=",(string nTot),", FAIL=",(string nFail),", PARSEERR=",(string nPE);
exit nFail+nPE;
