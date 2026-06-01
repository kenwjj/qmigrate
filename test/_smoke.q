/ Manual smoke check for the .qm DSL (not a test framework — see memory).
/ Run: QLIC=/c/q QHOME=/c/q /c/q/w64/q.exe _smoke.q -q

\l src/qm.q

ok:0; fail:0;
chk:{[d;c] $[c; [ok+:1; -1 "  ok   ",d]; [fail+:1; -1 "  FAIL ",d]] };
thr:{[f;a] 1b~@[f;a;{[e]1b}] };                / true if f[a] signals

-1 "--- positive: build schemas ---";
tr:.qm.schema[`trade] (
  .qm.partitioned[`date];
  .qm.col [`time;`timestamp]; .qm.colx[`sym;`symbol;`attr`p];
  .qm.col [`price;`float]; .qm.col [`size;`long];
  .qm.colx[`exchange;`symbol;`default`attr!(`NYSE;`g)] );
chk["trade name";          tr[`name]~`trade];
chk["trade kind";          tr[`kind]~`partitioned];
chk["trade partitionField";tr[`partitionField]~`date];
chk["trade 5 cols";        5=count tr`columns];
ex:first ?[tr`columns;enlist(=;`name;enlist`exchange);0b;()];   / exchange row
chk["exchange default";    ex[`default]~`NYSE];
chk["exchange attr g";     ex[`attr]~`g];
sy:first ?[tr`columns;enlist(=;`name;enlist`sym);0b;()];
chk["sym attr p";          sy[`attr]~`p];
chk["plain col attr empty";(first?[tr`columns;enlist(=;`name;enlist`time);0b;()])[`attr]~`];

ob:.qm.schema[`orderbook] (
  .qm.partitioned[`date];
  .qm.col [`time;`timestamp]; .qm.colx[`sym;`symbol;`attr`p];
  .qm.colx[`bid_prices;`float;`list`true] );
bp:first ?[ob`columns;enlist(=;`name;enlist`bid_prices);0b;()];
chk["list`true -> 1b";     bp[`list]~1b];
chk["non-list col -> 0b";  (first?[ob`columns;enlist(=;`name;enlist`time);0b;()])[`list]~0b];

cf:.qm.schema[`config] (.qm.memory[]; .qm.colx[`key;`symbol;`attr`u]; .qm.col[`value;`string]);
chk["memory kind";         cf[`kind]~`memory];
chk["memory partField `";  cf[`partitionField]~`];

df:.qm.schema[`tr] (.qm.partitioned[`date]; .qm.col[`time;`timestamp];
  .qm.colx[`load_date;`date;`defaultFn`.user.computeLoadDate] );
ld:first ?[df`columns;enlist(=;`name;enlist`load_date);0b;()];
chk["defaultFn stored";    ld[`defaultFn]~`.user.computeLoadDate];
chk["defaultFn default ::";(::)~ld`default];

-1 "--- negative: validation throws (spec §7) ---";
chk["unknown type";        thr[.qm.schema[`t];(.qm.memory[];.qm.col[`x;`notatype])]];
chk["string cannot list";  thr[.qm.schema[`t];(.qm.memory[];.qm.colx[`x;`string;`list`true])]];
chk["unknown mod key";     thr[.qm.colx[`x;`int];enlist`foo`bar]];  / colx 3rd arg
chk["both default+fn";     thr[.qm.schema[`t];(.qm.memory[];.qm.colx[`x;`int;`default`defaultFn!(5;`f)])]];
chk["invalid attr";        thr[.qm.schema[`t];(.qm.memory[];.qm.colx[`x;`int;`attr`z])]];
chk["dup col names";       thr[.qm.schema[`t];(.qm.memory[];.qm.col[`x;`int];.qm.col[`x;`long])]];
chk["no shape";            thr[.qm.schema[`t];enlist .qm.col[`x;`int]]];
chk["two shapes";          thr[.qm.schema[`t];(.qm.memory[];.qm.splayed[];.qm.col[`x;`int])]];
chk["no cols";             thr[.qm.schema[`t];enlist .qm.memory[]]];
chk["name not symbol";     thr[.qm.schema["t"];(.qm.memory[];.qm.col[`x;`int])]];
chk["shorthand bad len";   thr[.qm.colx[`x;`int];enlist`a`b`c]];
chk["defaultFn not sym";   thr[.qm.schema[`t];(.qm.memory[];.qm.colx[`x;`int;(enlist`defaultFn)!enlist 5])]];

-1 "--- loadSchemas ---";
s:.qm.loadSchemas `:schemas;
chk["loaded 4 tables";     4=count s];
chk["keys = table names";  (asc key s)~`config`instruments`orderbook`trade];
chk["instruments splayed"; s[`instruments;`kind]~`splayed];

-1 "";
-1 "RESULT  ok=",string[ok]," fail=",string fail;
exit fail
