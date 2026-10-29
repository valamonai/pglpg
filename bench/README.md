# Benchmark

`bench/run.rb` loads a synthetic graph and times the SQL pglpg generates,
with a `classification <= clearance` visibility policy on every node and edge.

- **Data** (scale 1): 200k nodes (Person, Incident, Location, Organization) and
  about 1.2M edges, including about 200k symmetric `FRIEND` edges stored once per
  pair. Edge sources are skewed (`random()^2`), so low ids are hubs.
  Access levels: 70% L1, 15% L2, 10% L3, 5% L4.
- **Shapes**: key lookup, 1–3 hop patterns from random people, a 3-hop pattern
  from the largest hub, a filtered hop, a count, and symmetric (`both`) 1- and
  2-hop patterns, including from the node with the most `FRIEND` edges. Each runs `BENCH_RUNS` times
  for a viewer at L2 and at L4.
- **Work**: besides time, it reports the shared buffers the hub query and the
  symmetric hub query touch
  (`EXPLAIN (ANALYZE, BUFFERS)`). A row limit bounds what is returned, not what
  is scanned, so time and buffers are both checked.

| Variable | Default | Meaning |
|---|---|---|
| `PGLPG_BENCH_DATABASE_URL` | `postgres:///pglpg_bench` | Database (created by you) |
| `BENCH_SCALE` | `1` | Data size multiplier |
| `BENCH_RUNS` | `300` | Runs per shape and viewer |
| `BENCH_RELOAD` | unset | `1` reloads the data |
| `BENCH_MAX_P95_MS` | `500` | Fail if any shape's p95 exceeds this |
| `BENCH_MAX_BUFFERS` | `100000` | Fail if either hub query touches more buffers |
| `BENCH_PLAN` | unset | `1` prints both hub query plans |

CI runs it at scale 0.2 on PostgreSQL 18, as a step of the single CI job. Laptop numbers with a warm cache
are not production numbers; expect a small managed instance to be several
times slower.
