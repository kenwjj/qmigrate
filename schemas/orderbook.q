/ schemas/orderbook.q — vector columns (spec §8.4)

.qm.schema[`orderbook] (
  .qm.partitioned[`date];

  .qm.col [`time;       `timestamp];
  .qm.colx[`sym;        `symbol;     `attr`p];
  .qm.colx[`bid_prices; `float;      `list`true];
  .qm.colx[`bid_sizes;  `long;       `list`true];
  .qm.colx[`ask_prices; `float;      `list`true];
  .qm.colx[`ask_sizes;  `long;       `list`true]
  )
