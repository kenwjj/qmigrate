/ qmigrate — native q schema DSL  (Phase 1)
/ Canonical reference: schema-spec.md v0.1
//
/ Public surface (all pure; no side effects except loadSchemas):
/   .qm.partitioned .qm.splayed .qm.memory   — table-shape helpers
/   .qm.col .qm.colx                          — column helpers
/   .qm.schema                                — schema constructor (validates)
/   .qm.loadSchemas                           — directory loader (file I/O)

\d .qm

/ ---------------------------------------------------------------------------
/ Vocabulary (spec §4, §5)
/ ---------------------------------------------------------------------------
types  :`boolean`byte`short`int`long`real`float`char`symbol`timestamp`month`date`datetime`timespan`minute`second`time`guid`string;
attrs  :`p`s`u`g;
modKeys:`attr`default`defaultFn`list;

/ ---------------------------------------------------------------------------
/ Internal helpers (.qm.i.*)
/ ---------------------------------------------------------------------------

/ Coerce a `list` modifier value to boolean.
/ Spec §8.4 writes the shorthand `list`true ; §6/§7.3 store/validate it as a
/ boolean. We accept the `true/`false symbols and the boolean form; anything
/ else passes through unchanged so §7.3 validation rejects it.
i.toBool:{[v] $[-1h=type v; v; v~`true; 1b; v~`false; 0b; v] };

/ Normalise a modifier argument into a full 4-key dict.
/ Accepts: a dict, or a 2-element symbol list shorthand (spec §5.1).
i.normMods:{[mods]
  if[99h<>type mods;                                   / not a dict -> shorthand list
    if[2<>count mods; '"qm: modifier shorthand must be a 2-element list"];
    mods:(enlist mods 0)!enlist mods 1
  ];
  bad:key[mods] except modKeys;                        / §7.3 unknown key
  if[count bad; '"qm: unknown modifier key(s): ",", " sv string bad];
  m:modKeys!(`;(::);`;0b);                             / attr default defaultFn list
  m:m,mods;
  m[`list]:i.toBool m`list;
  m };

/ Recursively list *.q files under a directory (filepath symbol e.g. `:schemas).
i.qfiles:{[dir]
  items:key dir;
  if[not 11h=type items; :()];                         / not a directory / empty
  paths:` sv/:dir,/:items;
  isDir:{11h=type key x} each paths;
  files:paths where (not isDir) & paths like "*.q";
  files,raze i.qfiles each paths where isDir };

/ Read a schema file and evaluate its single expression to a schema dict.
i.evalFile:{[f] value "\n" sv read0 f };

/ ---------------------------------------------------------------------------
/ Table-shape helpers (spec §3.1)
/ ---------------------------------------------------------------------------
partitioned:{[partField] `qm`kind`partitionField!(`shape;`partitioned;partField) };
splayed:{[] `qm`kind`partitionField!(`shape;`splayed;`) };
memory :{[] `qm`kind`partitionField!(`shape;`memory;`) };

/ ---------------------------------------------------------------------------
/ Column helpers (spec §3.2)
/ ---------------------------------------------------------------------------
colx:{[name;typ;mods]
  m:i.normMods mods;
  `qm`name`type`list`attr`default`defaultFn!(`col;name;typ;m`list;m`attr;m`default;m`defaultFn) };

col:{[name;typ] colx[name;typ;()!()] };

/ ---------------------------------------------------------------------------
/ Schema constructor (spec §3.3, validation §7)
/ ---------------------------------------------------------------------------
schema:{[name;parts]
  if[not -11h=type name; '"qm: table name must be a symbol"];           / §7.1
  if[0=count parts; '"qm: schema has no parts"];                         / §7.1

  tag:{x`qm} each parts;
  shapes:parts where tag=`shape;
  colz  :parts where tag=`col;

  ns:string name;
  if[0=count shapes; '"qm: schema '",ns,"' has no table-shape helper"];   / §7.1
  if[1<count shapes; '"qm: schema '",ns,"' has multiple table-shape helpers"]; / §7.1
  if[0=count colz;   '"qm: schema '",ns,"' has no columns"];             / §7.1

  cn:{x`name} each colz;
  if[count[cn]<>count distinct cn;                                       / §7.1
    '"qm: schema '",ns,"' has duplicate column names"];

  / per-column validation (§7.2, §7.3)
  {[ns;c]
    cs:string c`name;
    t:c`type;
    if[not t in types; '"qm: column '",cs,"' in '",ns,"' has unknown type '",string[t],"'"]; / §7.2
    l:c`list;
    if[not -1h=type l; '"qm: column '",cs,"' in '",ns,"' list modifier must be boolean"];    / §7.3
    if[(t=`string)&l;  '"qm: column '",cs,"' in '",ns,"' is type string and cannot be a list"]; / §7.2
    a:c`attr;
    if[not a in `,attrs; '"qm: column '",cs,"' in '",ns,"' has invalid attr '",string[a],"'"]; / §7.3
    df:c`defaultFn;
    if[not -11h=type df; '"qm: column '",cs,"' in '",ns,"' defaultFn must be a symbol"];        / §7.3
    if[(not (::)~c`default) & not df~`;                                   / §7.3 both set
      '"qm: column '",cs,"' in '",ns,"' has both default and defaultFn"];
   }[ns] each colz;

  / Build the columns table. Must use flip (not `([]...)`): `type` and `attr`
  / are reserved words and cannot appear as literal column-name tokens.
  colTab:flip `name`type`list`attr`default`defaultFn!(
    {x`name}      each colz;
    {x`type}      each colz;
    {x`list}      each colz;
    {x`attr}      each colz;
    {x`default}   each colz;
    {x`defaultFn} each colz );

  shp:first shapes;
  `name`kind`partitionField`columns!(name; shp`kind; shp`partitionField; colTab) };

/ ---------------------------------------------------------------------------
/ Loader (spec §3.4, validation §7.4)
/ ---------------------------------------------------------------------------
loadSchemas:{[dir]
  files:i.qfiles dir;
  schemas:{[f]
    @[i.evalFile;f;{[f;e] '"qm: failed to evaluate '",string[f],"' : ",e}[f]]
   } each files;
  / each result must be a valid schema dict (carries `name)
  bad:where not {(99h=type x) & `name in key x} each schemas;
  if[count bad; '"qm: file did not return a valid schema: ",string first files bad];
  names:schemas@\:`name;
  if[count[names]<>count distinct names;                                 / §7.4 dup table
    dups:where 1<count each group names;
    '"qm: duplicate table name(s) across files: ",", " sv string distinct names dups];
  names!schemas };

\d .
