/ schemas/trade.q — partitioned table (spec §8.1)

.qm.schema[`trade] (
  .qm.partitioned[`date];

  .qm.col [`time;     `timestamp];
  .qm.colx[`sym;      `symbol;    `attr`p];
  .qm.col [`price;    `float];
  .qm.col [`size;     `long];
  .qm.colx[`exchange; `symbol;    `default`attr!(`NYSE;`g)]
  )
