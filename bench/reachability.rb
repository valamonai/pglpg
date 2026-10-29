# frozen_string_literal: true

# Spike for 0.2 task "Benchmark reachability executors": compares three ways
# to compute bounded, minimum-depth reachability with the visibility policy on
# every edge and every next node. Uses a fixture that bench/measure.rb
# loads; load one first. See bench/README.md.
#
#   bundle exec ruby bench/reachability.rb
#   REACH_RUNS=50 REACH_MAX_NODES=500 bundle exec ruby bench/reachability.rb
#   REACH_NO_PARALLEL=1 …   # without parallel workers
#
# Executors (contract: task "0.2: reachable API", bb topic 145 posts 4–12):
#
#   per_hop   One statement per hop over the current frontier, in one
#             REPEATABLE READ READ ONLY transaction. Each hop fetches
#             remaining + 1 rows; an exactly full result probes the next hop
#             with LIMIT 1.
#   cte_walk  One recursive CTE over (node, depth) pairs (UNION), then
#             min(depth) per node. Revisits nodes at every depth they are
#             reachable at; no per-level cap.
#   cte_bfs   One recursive CTE whose rows are whole levels: frontier and
#             visited arrays, the next level computed in a LATERAL subquery
#             with the same remaining + 1 cap. The probe falls out of the cap.
#
# All three return [[id, depth], ...] ordered by (depth, id), plus complete
# and stopped_at_depth, and are checked to agree before anything is timed.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "pglpg"
require "json"

url = ENV.fetch("PGLPG_BENCH_DATABASE_URL", "postgres:///pglpg_bench")
runs = Integer(ENV.fetch("REACH_RUNS", "100"))
hub_runs = Integer(ENV.fetch("REACH_HUB_RUNS", "20"))
max_nodes = Integer(ENV.fetch("REACH_MAX_NODES", "500"))
checks = Integer(ENV.fetch("REACH_CHECKS", "200"))
timeout_ms = Integer(ENV.fetch("REACH_TIMEOUT_MS", "10000"))

ActiveRecord::Base.establish_connection(url)
pg = ActiveRecord::Base.connection.raw_connection
pg.type_map_for_results = PG::BasicTypeMapForResults.new(pg)
pg.exec("SET statement_timeout = #{timeout_ms}")
pg.exec("SET max_parallel_workers_per_gather = 0") if ENV["REACH_NO_PARALLEL"] == "1"

N = "bench_nodes"
E = "bench_edges"
raise "no bench data in #{url}; load one with bench/measure.rb --load-only first" unless pg.exec("SELECT to_regclass('#{N}')").getvalue(0, 0)

Result = Data.define(:nodes, :complete, :stopped_at_depth)

# Where a hop goes from frontier ids: directed out, or symmetric (both ends).
module Steps
  module_function

  # SQL producing column "far" for edges leaving any id in +frontier+.
  def far(dir, frontier, types, clearance)
    vis = "e.classification <= #{clearance}"
    out = "SELECT e.target_id AS far FROM #{E} e WHERE e.source_id = ANY(#{frontier}) AND e.type = ANY(#{types}) AND #{vis}"
    return out if dir == :out

    "#{out} UNION ALL SELECT e.source_id FROM #{E} e WHERE e.target_id = ANY(#{frontier}) " \
      "AND e.type = ANY(#{types}) AND #{vis}"
  end

  # SQL joining one edge from walk alias +w+ (single node w.id).
  def walk_join(dir, types, clearance)
    vis = "e.classification <= #{clearance}"
    if dir == :out
      "JOIN #{E} e ON e.source_id = w.id AND e.type = ANY(#{types}) AND #{vis} " \
        "JOIN #{N} n ON n.id = e.target_id AND n.classification <= #{clearance}"
    else
      "JOIN #{E} e ON (e.source_id = w.id OR e.target_id = w.id) AND e.type = ANY(#{types}) AND #{vis} " \
        "JOIN #{N} n ON n.id = (CASE WHEN e.source_id = w.id THEN e.target_id ELSE e.source_id END) " \
        "AND n.classification <= #{clearance}"
    end
  end
end

def text_array(values) = PG::TextEncoder::Array.new.encode(values)

def visible_start?(pg, start, clearance)
  pg.exec_params("SELECT 1 FROM #{N} WHERE id = $1 AND classification <= $2", [start, clearance]).ntuples == 1
end

# --- per_hop -----------------------------------------------------------------

def per_hop_sql(dir, clearance)
  <<~SQL
    SELECT DISTINCT n.id FROM (#{Steps.far(dir, "$1::bigint[]", "$2::text[]", clearance)}) x
    JOIN #{N} n ON n.id = x.far AND n.classification <= #{clearance}
    WHERE n.id <> ALL($3::bigint[])
    ORDER BY n.id LIMIT $4
  SQL
end

def per_hop(pg, start:, types:, dir:, clearance:, max_depth:, max_nodes:, explain: nil)
  pg.exec("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
  return Result.new(nodes: [], complete: true, stopped_at_depth: nil) unless visible_start?(pg, start, clearance)

  sql = per_hop_sql(dir, clearance)
  hop = lambda do |frontier, visited, limit|
    params = [text_array(frontier), text_array(types), text_array(visited), limit]
    explain&.call(sql, params)
    pg.exec_params(sql, params).column_values(0)
  end
  found = []
  visited = [start]
  frontier = [start]
  (1..max_depth).each do |depth|
    break if frontier.empty?

    remaining = max_nodes - found.size
    ids = hop.(frontier, visited, remaining + 1)
    if ids.size > remaining
      found.concat(ids.first(remaining).map { [_1, depth] })
      return Result.new(nodes: found, complete: false, stopped_at_depth: depth)
    end
    found.concat(ids.map { [_1, depth] })
    visited.concat(ids)
    frontier = ids
    next unless found.size == max_nodes && depth < max_depth && frontier.any?

    # Exactly full with depth left: one probe of the next hop.
    more = hop.(frontier, visited, 1).any?
    return Result.new(nodes: found, complete: !more, stopped_at_depth: more ? depth : nil)
  end
  Result.new(nodes: found, complete: true, stopped_at_depth: nil)
ensure
  pg.exec("COMMIT")
end

# --- cte_walk ----------------------------------------------------------------

def cte_walk_sql(dir, clearance)
  <<~SQL
    WITH RECURSIVE walk(id, depth) AS (
      SELECT n.id, 0 FROM #{N} n WHERE n.id = $1 AND n.classification <= #{clearance}
      UNION
      SELECT n.id, w.depth + 1 FROM walk w #{Steps.walk_join(dir, "$2::text[]", clearance)}
      WHERE w.depth < $3
    )
    SELECT id, min(depth) AS depth FROM walk WHERE id <> $1 GROUP BY id ORDER BY 2, 1 LIMIT $4
  SQL
end

def cte_walk(pg, start:, types:, dir:, clearance:, max_depth:, max_nodes:, explain: nil)
  sql = cte_walk_sql(dir, clearance)
  params = [start, text_array(types), max_depth, max_nodes + 1]
  explain&.call(sql, params)
  rows = pg.exec_params(sql, params).values
  # The CTE computes the whole answer, so completeness is exact.
  if rows.size > max_nodes
    Result.new(nodes: rows.first(max_nodes), complete: false, stopped_at_depth: rows[max_nodes - 1][1])
  else
    Result.new(nodes: rows, complete: true, stopped_at_depth: nil)
  end
end

# --- cte_bfs -----------------------------------------------------------------

def cte_bfs_sql(dir, clearance)
  <<~SQL
    WITH RECURSIVE bfs(depth, frontier, visited) AS (
      SELECT 0, ARRAY[n.id], ARRAY[n.id] FROM #{N} n WHERE n.id = $1 AND n.classification <= #{clearance}
      UNION ALL
      SELECT b.depth + 1, nxt.ids, b.visited || nxt.ids
      FROM bfs b
      CROSS JOIN LATERAL (
        SELECT ARRAY(
          SELECT DISTINCT n.id FROM (#{Steps.far(dir, "b.frontier", "$2::text[]", clearance)}) x
          JOIN #{N} n ON n.id = x.far AND n.classification <= #{clearance}
          WHERE n.id <> ALL(b.visited)
          ORDER BY n.id
          LIMIT $4::int - cardinality(b.visited) + 2  -- remaining + 1; 1 when exactly full (the probe)
        ) AS ids
        OFFSET 0  -- keeps the level from being inlined, and so computed, once per reference
      ) nxt
      WHERE b.depth < $3 AND cardinality(b.frontier) > 0 AND cardinality(b.visited) - 1 <= $4::int
    )
    SELECT depth, frontier FROM bfs WHERE depth > 0 ORDER BY depth
  SQL
end

def cte_bfs(pg, start:, types:, dir:, clearance:, max_depth:, max_nodes:, explain: nil)
  sql = cte_bfs_sql(dir, clearance)
  params = [start, text_array(types), max_depth, max_nodes]
  explain&.call(sql, params)
  levels = pg.exec_params(sql, params).values
  all = levels.flat_map { |depth, ids| ids.map { [_1, depth] } }
  return Result.new(nodes: all, complete: true, stopped_at_depth: nil) if all.size <= max_nodes

  Result.new(nodes: all.first(max_nodes), complete: false, stopped_at_depth: all[max_nodes - 1][1])
end

# --- harness -----------------------------------------------------------------

EXECUTORS = { "per_hop" => method(:per_hop), "cte_walk" => method(:cte_walk), "cte_bfs" => method(:cte_bfs) }.freeze

persons = pg.exec("SELECT count(*) FROM #{N} WHERE key_label = 'Person'").getvalue(0, 0)
knows_hub = pg.exec("SELECT source_id FROM #{E} WHERE type = 'KNOWS' GROUP BY 1 ORDER BY count(*) DESC LIMIT 1").getvalue(0, 0)
friend_hub = pg.exec(<<~SQL).getvalue(0, 0)
  SELECT id FROM (SELECT source_id AS id FROM #{E} WHERE type = 'FRIEND'
                  UNION ALL SELECT target_id FROM #{E} WHERE type = 'FRIEND') x
  GROUP BY 1 ORDER BY count(*) DESC LIMIT 1
SQL
edges = pg.exec("SELECT count(*) FROM #{E}").getvalue(0, 0)

shapes = [
  { name: "KNOWS out, depth 2", types: %w[KNOWS], dir: :out, max_depth: 2 },
  { name: "KNOWS out, depth 3", types: %w[KNOWS], dir: :out, max_depth: 3 },
  { name: "FRIEND both, depth 2", types: %w[FRIEND], dir: :both, max_depth: 2 },
  { name: "FRIEND both, depth 3", types: %w[FRIEND], dir: :both, max_depth: 3 }
]
hub_for = ->(shape) { shape[:types] == %w[KNOWS] ? knows_hub : friend_hub }

# 1. Agreement: every executor returns the same result on random and hub starts,
#    for both clearances, with a small cap so truncation and the probe run too.
rng = Random.new(7)
mismatches = 0
compared = 0
shapes.each do |shape|
  starts = Array.new(checks) { 1 + rng.rand(persons) } + [hub_for.(shape)]
  starts.each do |start|
    [2, 4].each do |clearance|
      [max_nodes, 5, 20].each do |cap|
        args = { start:, types: shape[:types], dir: shape[:dir], clearance:, max_depth: shape[:max_depth], max_nodes: cap }
        results = EXECUTORS.transform_values { _1.(pg, **args) }
        compared += 1
        next if results.values.uniq.size == 1

        mismatches += 1
        warn "MISMATCH #{shape[:name]} start=#{start} L#{clearance} cap=#{cap}: " +
             results.map { |k, r| "#{k}=#{r.nodes.size}/#{r.complete}/#{r.stopped_at_depth}" }.join(" ")
      end
    end
  end
end
puts "agreement: #{compared - mismatches}/#{compared} comparisons identical"
abort "executors disagree" if mismatches.positive?

# 2. Timing and work.
def percentile(sorted, pct) = sorted[[(sorted.size * pct).ceil - 1, 0].max]

def buffers_of(pg, sql, params)
  plan = JSON.parse(pg.exec_params("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", params).getvalue(0, 0).to_json)
  plan = JSON.parse(plan) if plan.is_a?(String)
  top = plan.first["Plan"]
  top["Shared Hit Blocks"].to_i + top["Shared Read Blocks"].to_i
end

caps = ENV.fetch("REACH_CAPS", "#{max_nodes},5000").split(",").map { Integer(_1) }
buffer_samples = Integer(ENV.fetch("REACH_BUFFER_SAMPLES", "30"))

puts "\npglpg #{Pglpg::VERSION} · #{pg.exec("SHOW server_version").getvalue(0, 0)} · #{persons} persons · #{edges} edges · " \
     "#{runs} runs per random shape, #{hub_runs} per hub shape · L4 viewer\n\n"
puts "| Shape | Start | max_nodes | Executor | p50 (ms) | p95 (ms) | max (ms) | buffers p50 / p95 | nodes p95 | complete |"
puts "|---|---|---|---|---|---|---|---|---|---|"
fmt = ->(v) { v.infinite? ? "timeout" : format("%.2f", v) }
cell = 0
shapes.each do |shape|
  [[:random, runs], [:hub, hub_runs]].each do |kind, n|
    starts_rng = Random.new(42)
    starts = Array.new(n) { kind == :hub ? hub_for.(shape) : 1 + starts_rng.rand(persons) }
    caps.each do |cap|
      args = lambda { |start|
        { start:, types: shape[:types], dir: shape[:dir], clearance: 4, max_depth: shape[:max_depth], max_nodes: cap }
      }
      # Each executor gets its own block: warm every start (at least three
      # calls), then time them, so no executor pays for pages another one
      # loaded or evicted. Interleaving per start doesn't work here: from a
      # hub, cte_walk touches more pages than shared_buffers holds and evicts
      # whatever runs next. The block order rotates per cell, so none is
      # always first. An executor that times out in warm-up is not measured.
      warm = starts.uniq.cycle.first([starts.uniq.size, 3].max)
      times_by = {}
      results_by = {}
      EXECUTORS.keys.rotate(cell).each do |name|
        warm.each { EXECUTORS[name].(pg, **args.(_1)) }
        results_by[name] = []
        times_by[name] = starts.map do |start|
          t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          results_by[name] << EXECUTORS[name].(pg, **args.(start))
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
        rescue PG::QueryCanceled
          Float::INFINITY
        end
      rescue PG::QueryCanceled
        nil
      end
      cell += 1
      EXECUTORS.each do |name, exec|
        unless times_by.key?(name)
          puts "| #{shape[:name]} | #{kind} | #{cap} | #{name} | timeout in warm-up | | | | | |"
          next
        end
        times = times_by[name].sort
        results = results_by[name]
        buffers = starts.first(buffer_samples).map do |start|
          total = 0
          exec.(pg, **args.(start), explain: ->(sql, params) { total += buffers_of(pg, sql, params) })
          total
        rescue PG::QueryCanceled
          Float::INFINITY
        end.sort
        sizes = results.map { _1.nodes.size }.sort
        incomplete = results.count { !_1.complete }
        puts "| #{shape[:name]} | #{kind} | #{cap} | #{name} | #{fmt.(percentile(times, 0.5))} | #{fmt.(percentile(times, 0.95))} | " \
             "#{fmt.(times.last)} | #{percentile(buffers, 0.5)} / #{percentile(buffers, 0.95)} | #{percentile(sizes, 0.95)} | " \
             "#{incomplete.zero? ? "all" : "#{results.size - incomplete}/#{results.size}"} |"
      end
    end
  end
end
