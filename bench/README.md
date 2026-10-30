# Benchmark

Measures the SQL pglpg generates, through its public API, on seeded synthetic
graphs with a `classification <= clearance` visibility policy on every node
and edge. The contract is Kanban task 36367 ("0.2: CI benchmark job at 1M and
10M edges") and the review in bb topic 148.

```bash
createdb pglpg_bench_<worktree>
export PGLPG_BENCH_DATABASE_URL=postgres:///pglpg_bench_<worktree>
bundle exec ruby bench/measure.rb --fixture 1m --out tmp/bench/candidate   # loads the fixture if needed
ruby bench/gate.rb --candidate tmp/bench/candidate                         # absolute bounds
bundle exec rake bench FIXTURE=ci                                          # both, on the small fixture
```

## Fixtures (`bench/support/fixture.rb`)

Persons, incidents, locations and organizations, joined by `KNOWS`,
`INVOLVED_IN`, `OCCURRED_AT`, `MEMBER_OF` and symmetric `FRIEND` edges.
Access levels: 70% L1, 15% L2, 10% L3, 5% L4, on nodes and edges alike.
Edge sources are skewed (`random()^2`), so low ids are natural hubs: id 1 gets
about `count / sqrt(persons)` edges of each type.

| Fixture | Scale | Nodes | Edges | Extra hubs |
|---|---|---|---|---|
| `ci` | 0.2 | 40,000 | 200,000 | – |
| `1m` | 1 | 200,000 | 1,000,000 | – |
| `hub-heavy` | 1 | 200,000 | 1,160,000 | 20 |
| `10m` | 10 | 2,000,000 | 10,000,000 | – |

- **hub-heavy** adds 20 Person hubs, evenly spread over the Person ids. Each
  has 5,000 `KNOWS` out-edges, 2,000 `FRIEND` edges and 1,000 `INVOLVED_IN`
  edges to uniformly random ends. Their own levels cycle L1–L4, so every
  viewer sees some of them.
- **Seeded:** `setseed(0.42)` runs before the inserts, in one session without
  parallel inserts, so every load produces the same ids and edges.
- **Deterministic statistics:** `updated_at`, which no query reads, has a
  statistics target of 10,000, so `ANALYZE` reads every row of a table up to
  3M rows. Each column's statistics are still built at its own target, and
  every other column keeps the default. Below that size, the statistics, the
  plans and the buffer counts are the same on every load and every machine.
  - Without this, one cell touched 414 buffers on one load and 10 on another.
  - Raising the target on every column instead made each hub query spend
    over 100 ms planning: the join estimate compares MCV lists pairwise.
  - The `10m` edges table is larger than 3M rows, so `ANALYZE` still samples
    it.
- **Manifest:** the loader writes `bench_manifest` with the generator version,
  seed, fixture, scale, hubs, a fingerprint of the storage schema pglpg
  creates (tables, indexes and generated constraints), the counts and the load
  time. A database is used only when its manifest matches. Otherwise the
  candidate reloads it, and a baseline reports itself unavailable.
  `GENERATOR_VERSION` changes whenever the generator does.
- **Sanity checks** run before any timing. Node counts and edge counts per type
  must match the fixture (FRIEND within 0.5%, for the dropped self pairs), and
  the top `KNOWS` out-degree must fall within 25% of the skew's expectation.
  On hub-heavy it must reach the extra hubs' 5,000.

## Cells (`bench/support/cells.rb`)

A cell is fixture × shape × viewer (L2, L4). Starts are chosen in SQL, the
same way for every revision. They come only from nodes the viewer can see,
and are ordered by `hashint8`, so the lists are stable:

- `random`: 50 visible persons.
- `knows_hub` / `friend_hub`: the 3 visible persons with the most visible
  `KNOWS` out-edges or `FRIEND` edges.
- `probe_negative` / `probe_positive`: 10 visible persons with exactly one
  visible `KNOWS` neighbour B, where B has no further visible neighbour
  (A → B) or does (A → B → C).

| Shape | Starts | Call |
|---|---|---|
| `find_by_key` | random | `find_node(:Person, uid:)` |
| `hop1`, `hop2`, `hop3` | random | 1–3 hop patterns, `limit(500)` |
| `hop3_hub` | knows_hub | the 3-hop pattern from a hub |
| `hop1_filtered` | random | 1 hop with `severity >= 4` |
| `count2_hub` | knows_hub | `count` of a 2-hop pattern |
| `sym1`, `sym2`, `sym2_hub` | random, friend_hub | symmetric `both(:FRIEND)` patterns |
| `reach_knows_overflow` | knows_hub | `reachable` out, depth 3, 500 nodes: must be incomplete |
| `reach_friend_overflow` | friend_hub | `reachable` both, depth 2, 100 nodes: must be incomplete |
| `reach_knows_depth2` | random | depth 2, 5,000 nodes: complete within the requested depth |
| `reach_probe_negative` | probe_negative | depth 2, 1 node: `B@1`, complete |
| `reach_probe_positive` | probe_positive | depth 2, 1 node: `B@1`, incomplete, stopped at depth 1 |
| `reach_probe_depth_bound` | probe_positive | depth 1, 1 node: `B@1`, complete |

## Protocol (`bench/measure.rb`)

For each cell:

1. **Warm-up and workload:** one call per start (at least three calls). Each
   result is checked against the cell's exact expectation, and its size is
   recorded: total rows and non-empty starts.
2. **Latency:** `BENCH_RUNS` (200) calls over random starts, or
   `BENCH_HUB_RUNS` (30) over hub and probe starts, cycling through the list.
   Each call is timed around the public API call, Ruby included, on a warm
   cache.
3. **Buffers:** a separate pass over up to `BENCH_PLANS` (20) starts. The one
   statement each call runs is captured (pglpg names its reads `Pglpg`; any
   other count is an error). It then runs under
   `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`, and the buffers are the top
   node's `Shared Hit Blocks + Shared Read Blocks`. A missing value is an
   error, never 0.

The gated statistics are p95 latency over the timed calls, and p95 buffers
over the plans. A timeout (`BENCH_TIMEOUT_MS`, 30,000 ms), an error, or an
unmet expectation fails that cell, and the other cells still run. A cell
whose API the revision lacks is `unsupported`.

`results.json` holds every cell with its start ids, workload, latency and
buffers, plus the manifest, stats, SHA and elapsed time. `plans/` holds the
JSON plans of every sampled start, and the text plan of the start that
touched the most buffers.

`PGLPG_LIB` points the driver at another revision's `lib/`. That is how a
baseline is measured with the candidate's driver, shapes and starts. The
driver refuses to run if any pglpg file is loaded from elsewhere.

## Gate (`bench/gate.rb`, `bench/bounds.yml`)

- **Absolute:** every measured cell needs a bound in `bounds.yml`, and every
  bound needs a measured cell. A cell fails when its p95 latency or p95
  buffers exceed the bound, or when its workload falls below `min_total` rows
  or `min_nonempty` starts.
- **Relative** (`--baseline`): buffers may grow by 10% (or by 5 buffers, if
  that's more) over the baseline. p95 latency may grow 2×, with both sides
  raised to 1 ms first. That ratio is a coarse slowdown guard, because
  shared-runner latency is noisy. Both thresholds live in `bounds.yml`.
  - A missing or failed baseline cell always fails the gate. Both revisions
    run the same driver, so either one means a broken measurement.
  - A cell whose API the baseline lacks (`unsupported`) is reported. It fails
    only with `--require-baseline`, which also fails an unavailable baseline.
- `bench/calibrate.rb RESULTS_DIR…` rewrites a fixture's bounds from measured
  results, preferably the `bench-<fixture>` CI artifacts. It proposes 3× p95
  latency (at least 10 ms, at most the 500 ms target for 3-hop shapes on 1m),
  3× p95 buffers plus 10, and 80% of the workload. Review the diff before
  committing it.
- **Buffer bounds have room for a plan change.** On `10m`, `ANALYZE` still
  samples the edges table (see *Fixtures*), so its plans can differ from load
  to load. The relative gate compares revisions on one load and one set of
  statistics, so it stays tight on every fixture.
- `bench/selftest.rb RESULTS_DIR` derives bounds that the results meet
  exactly. It then breaches a latency bound, a buffer bound, a workload
  minimum, a cell's status, a missing bound and the baseline comparison in
  turn. It asserts that the gate exits 1 on each, and 0 on the
  untouched results. It also checks that buffer extraction raises on
  incomplete plans.

## CI

- **`ci.yml`**, on every push: the `ci` fixture, then the self-test, then the
  absolute gate. Results go to the job summary and the `bench-ci` artifact.
- **`bench.yml`** runs on pull requests that touch `lib/`, `bench/` or the
  dependencies, every Monday, and on demand. Each fixture runs in its own job
  with its own database: load and check the fixture, measure the baseline,
  measure the candidate, then gate. Plans and results are uploaded even when
  the job fails (`bench-<fixture>` artifacts, kept 90 days).
  - **Baseline:** a pull request compares with its merge-base on the target
    branch. A scheduled or manual run uses the `baseline` input, or else
    `bench/BASELINE`, the last accepted baseline. Update that file in a PR,
    after reviewing a run, to accept a new one.
  - **10m** doesn't run on pull requests. Scheduled runs gate it on absolute
    bounds only. A manual run with `compare_10m` compares it too, with
    `--require-baseline` on every compared fixture (1m, hub-heavy and 10m).
    That comparison is required once to finish task
    36367, and again for the release candidate before 0.2 (release gate
    36368).

Laptop numbers with a warm cache are not production numbers; expect a small
managed instance to be several times slower.

## Reachability executors (`bench/reachability.rb`)

A spike for the 0.2 `reachable` API. It runs on a fixture that
`bench/measure.rb` has loaded. It compares three ways of computing bounded,
minimum-depth reachability, with the visibility policy on every edge and every
next node:

- **`per_hop`:** one statement per hop over the current frontier, in one `REPEATABLE READ READ ONLY` transaction.
- **`cte_walk`:** one recursive CTE over (node, depth) pairs, then `min(depth)` per node.
- **`cte_bfs`:** one recursive CTE whose rows are whole levels (frontier and visited arrays), with the same `remaining + 1` cap per level.

Before anything is timed, the script checks that all three return identical results on random and hub starts, at two clearances and several caps. It then times each executor in its own block, right after warming every start with it, with the block order rotating from cell to cell, and reports p50 and p95 latency and shared buffers (`EXPLAIN (ANALYZE, BUFFERS)`) per shape, start kind and `max_nodes`. An executor that times out during warm-up is reported as such and not measured. It measures handwritten executors, not pglpg's `reachable`; the CI benchmark above measures that.

| Variable | Default | Meaning |
|---|---|---|
| `REACH_RUNS` / `REACH_HUB_RUNS` | `100` / `20` | Runs per shape from random starts / from the hub |
| `REACH_MAX_NODES`, `REACH_CAPS` | `500`, `500,5000` | Result caps to measure |
| `REACH_CHECKS` | `200` | Random starts in the agreement check |
| `REACH_BUFFER_SAMPLES` | `30` | Starts measured with `EXPLAIN` |
| `REACH_TIMEOUT_MS` | `10000` | Statement timeout |
| `REACH_NO_PARALLEL` | unset | `1` disables parallel workers |
