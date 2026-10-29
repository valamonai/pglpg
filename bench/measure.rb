# frozen_string_literal: true

# Measures every cell of one fixture with one pglpg revision and writes
# results.json and plans/ to the output directory. bench/gate.rb decides
# pass or fail. See bench/README.md.
#
#   bundle exec ruby bench/measure.rb --fixture 1m --out tmp/bench/candidate
#   PGLPG_LIB=../baseline/lib bundle exec ruby bench/measure.rb --fixture 1m --out tmp/bench/baseline --baseline
#
# The candidate loads the fixture when the database doesn't hold it. A
# baseline never loads: it measures the candidate's fixture, or reports the
# baseline unavailable when the fixture doesn't match its storage schema.

require "fileutils"
require "json"
require "optparse"

opts = { baseline: false, load: true }
OptionParser.new do |o|
  o.on("--fixture NAME") { opts[:fixture] = _1 }
  o.on("--out DIR") { opts[:out] = _1 }
  o.on("--baseline", "measure a baseline revision: never load") { opts[:baseline] = true }
  o.on("--load-only", "load and check the fixture, measure nothing") { opts[:load_only] = true }
  o.on("--no-load", "fail instead of loading") { opts[:load] = false }
  o.on("--reload", "load even when the fixture matches") { opts[:reload] = true }
end.parse!
fixture = opts.fetch(:fixture) { abort "--fixture is required" }
out = opts[:out]
abort "--out is required" unless out || opts[:load_only]

lib = File.expand_path(ENV.fetch("PGLPG_LIB", File.expand_path("../lib", __dir__)))
$LOAD_PATH.unshift lib
# Bundler has loaded this checkout's version.rb through the gemspec. Forget
# it, so the measured lib defines its own.
if defined?(Pglpg::VERSION)
  Pglpg.send(:remove_const, :VERSION)
  $LOADED_FEATURES.reject! { _1.end_with?("/lib/pglpg/version.rb") }
end
require "pglpg"
foreign = $LOADED_FEATURES.grep(%r{/lib/pglpg(\.rb|/)}).reject { _1.start_with?("#{lib}/") }
abort "pglpg loaded from outside #{lib}: #{foreign.first}" if foreign.any?

require_relative "support/graph"
require_relative "support/fixture"
require_relative "support/plan"
require_relative "support/cells"

runs = Integer(ENV.fetch("BENCH_RUNS", "200"))
hub_runs = Integer(ENV.fetch("BENCH_HUB_RUNS", "30"))
plans = Integer(ENV.fetch("BENCH_PLANS", "20"))
timeout_ms = Integer(ENV.fetch("BENCH_TIMEOUT_MS", "30000"))
sha = ENV["BENCH_SHA"] || `git -C #{lib} rev-parse HEAD 2>/dev/null`.strip
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

ActiveRecord::Base.establish_connection(ENV.fetch("PGLPG_BENCH_DATABASE_URL", "postgres:///pglpg_bench"))
conn = ActiveRecord::Base.connection
graph = BenchGraph.define
Pglpg.configure do |c|
  c.statement_timeout = nil # the session timeout below applies instead
  c.max_rows = 10_000
end

write = lambda do |result|
  FileUtils.mkdir_p(out)
  File.write(File.join(out, "results.json"), JSON.pretty_generate(result))
end
base = { "role" => opts[:baseline] ? "baseline" : "candidate", "sha" => sha, "fixture" => fixture,
         "pglpg_version" => Pglpg::VERSION, "server_version" => conn.select_value("SHOW server_version") }

reason = Fixture.mismatch(conn, fixture, graph)
reason ||= "--reload" if opts[:reload] && !opts[:baseline]
if reason
  if opts[:baseline]
    warn "baseline unavailable: #{reason}"
    write.(base.merge("unavailable" => reason))
    exit 0
  end
  abort "fixture #{fixture} not loaded (#{reason}) and --no-load given" unless opts[:load]
  puts "loading fixture #{fixture} (#{reason})…"
  Fixture.load!(conn, fixture, graph)
end
manifest = Fixture.manifest(conn)
stats = Fixture.stats(conn, fixture, graph)
Fixture.sanity!(stats, fixture)
puts "fixture #{fixture}: #{stats["nodes"].values.sum} nodes, #{stats["edges"].values.sum} edges, " \
     "top KNOWS out-degree #{stats["top_knows_out_degree"]} (loaded in #{manifest["load_seconds"]} s)"
exit 0 if opts[:load_only]

starts = BenchGraph::CLEARANCES.to_h { [_1, Cells.starts(conn, graph, _1)] }
conn.execute("SET statement_timeout = #{timeout_ms}")
plan_dir = File.join(out, "plans")
FileUtils.mkdir_p(plan_dir)

def percentile(sorted, pct) = sorted[[(sorted.size * pct).ceil - 1, 0].max]

def summary(values)
  sorted = values.sort
  { "p50" => percentile(sorted, 0.5), "p95" => percentile(sorted, 0.95), "max" => sorted.last, "samples" => sorted.size }
end

def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

cells = {}
Cells.all(graph).each do |cell|
  BenchGraph::CLEARANCES.each do |clearance|
    key = "#{fixture}/#{cell.id}/L#{clearance}"
    ids = starts[clearance].fetch(cell.starts)
    g = graph.for(viewer: BenchGraph::Viewer.new(clearance))
    row = { "fixture" => fixture, "shape" => cell.id, "clearance" => clearance, "start_kind" => cell.starts.to_s,
            "starts" => ids.size, "errors" => [] }
    cells[key] = row
    if cell.requires && !cell.requires.(g)
      row["status"] = "unsupported"
      next
    end
    if ids.empty?
      row["status"] = "failed"
      row["errors"] << "no visible #{cell.starts} starts"
      next
    end

    begin
      # Warm-up: every start at least once (three calls minimum). Its
      # results are the workload checks, kept per start as evidence.
      per_start = ids.map do |id|
        r = cell.run.(g, id)
        (msg = cell.check.(r)) && row["errors"] << "start #{id}: #{msg}"
        record = { "id" => id, "size" => cell.size.(r) }
        record.merge!("complete" => r.complete, "stopped_at_depth" => r.stopped_at_depth) if r.respond_to?(:stopped_at_depth)
        record
      end
      (3 - ids.size).times { cell.run.(g, ids.first) } if ids.size < 3
      sizes = per_start.map { _1["size"] }
      row["workload"] = { "total" => sizes.sum, "nonempty" => sizes.count(&:positive?), "starts" => sizes.size }
      row["per_start"] = per_start

      n = cell.starts == :random ? runs : hub_runs
      times = Array.new(n) do |i|
        t = clock
        cell.run.(g, ids[i % ids.size])
        (clock - t) * 1000
      end
      row["latency_ms"] = summary(times).transform_values { _1.is_a?(Float) ? _1.round(3) : _1 }

      # EXPLAIN in a separate pass, never during the timed calls.
      measured = ids.first(plans).map do |id|
        statement, = Plan.capture { cell.run.(g, id) }
        plan = Plan.explain(conn, statement)
        [id, statement, plan, Plan.buffers(plan)]
      end
      row["buffers"] = summary(measured.map(&:last))
      measured.each { |id, *, buffers| per_start.find { _1["id"] == id }["buffers"] = buffers }
      worst = measured.max_by(&:last)
      slug = key.tr("/", "_")
      File.write(File.join(plan_dir, "#{slug}.json"), JSON.pretty_generate(measured.to_h { [_1.first.to_s, _1[2]] }))
      File.write(File.join(plan_dir, "#{slug}.txt"),
                 "-- #{key}, start #{worst.first}, #{worst.last} buffers\n#{Plan.explain_text(conn, worst[1]).join("\n")}\n")
    rescue Pglpg::QueryTimeout, ActiveRecord::QueryCanceled => e
      row["errors"] << "timeout (#{timeout_ms} ms): #{e.message.lines.first&.strip}"
    rescue StandardError => e
      row["errors"] << "#{e.class}: #{e.message.lines.first&.strip}"
    end
    row["status"] = row["errors"].empty? ? "ok" : "failed"
    lat = row.dig("latency_ms", "p95")
    puts format("%-44s %-11s p95 %9s ms  buffers p95 %8s  rows %s", key, row["status"], lat&.round(2),
                row.dig("buffers", "p95"), row.dig("workload", "total"))
  end
end

write.(base.merge("manifest" => manifest, "stats" => stats, "starts" => starts,
                  "elapsed_seconds" => (clock - started).round(1), "cells" => cells))
