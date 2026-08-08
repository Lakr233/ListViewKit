# ListViewKit Runtime Benchmarks

The benchmark uses deterministic fixed-height data sets containing 1,000,
10,000, and 100,000 rows. Each measurement isolates one path so a regression
can be attributed to a single subsystem:

- **Initial layout** — snapshot application and layout-cache construction.
- **20k visible queries** — visible-range resolution alone. The content offset
  is written once, then `indicesForVisibleRows` runs repeatedly against the
  same viewport, so the number reflects the binary search and nothing else.
- **20k offset writes** — `contentOffset` writes alone, with no row work. On
  AppKit this is what a scroll gesture costs before the list does anything.
- **1k scroll layouts** — full layout passes across the content height,
  including row recycling and reuse.
- **1k tail item updates** — direct item updates and targeted height
  invalidations of the final row, modeling a growing streaming response
  without diffing a complete snapshot or discarding unrelated cached
  measurements.
- **200 appends** — adding one row at a time through `append`, the path a chat
  client takes for every new message.
- **200 whole-array applies** — the same growth expressed as `apply`, which has
  to diff everything to discover the one new row. The gap between this and the
  previous column is what the incremental API buys.
- **20 width reflows** — alternating content widths, each invalidating every
  cached height and forcing a full synchronous re-measure.

The executable performs an unreported warm-up and prints the median of three
samples for each measurement.

Run an optimized build from the repository root:

```bash
swift run -c release ListViewKitBenchmarks
```

`LVK_ITEMS` and `LVK_BENCH` narrow a run while iterating on one path:

```bash
LVK_ITEMS=10000 LVK_BENCH=append,reflow swift run -c release ListViewKitBenchmarks
```

Results depend on hardware and toolchain versions. Compare changes using the
same machine, Swift version, and power conditions.
