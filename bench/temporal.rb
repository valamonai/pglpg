# frozen_string_literal: true

# Local/review temporal experiment, separate from the unchanged regression
# fixture/gates. Never point this at an application database. --load replaces
# the synthetic bench tables. The baseline uses the old library with an
# equivalent validity-aware policy; it is a compiler reference, not a claim
# that that release implements temporal contexts. See bench/README.md.
require "optparse"
require "json"
require "digest"
require "fileutils"

opts = { fixture: "1m", active_percent: 33, baseline: false, load: false }
OptionParser.new do |o|
  o.on("--fixture NAME") { opts[:fixture] = _1 }
  o.on("--out DIR") { opts[:out] = _1 }
  o.on("--active-percent N", Integer) { opts[:active_percent] = _1 }
  o.on("--load") { opts[:load] = true }
  o.on("--baseline") { opts[:baseline] = true }
  o.on("--compare DIR") { opts[:compare] = _1 }
end.parse!
abort "--out is required" unless opts[:out]
abort "active-percent must be 1..99" unless (1..99).cover?(opts[:active_percent])
abort "baseline must never load" if opts[:baseline] && opts[:load]
lib = File.expand_path(ENV.fetch("PGLPG_LIB", File.expand_path("../lib", __dir__)))
$LOAD_PATH.unshift(lib)
if defined?(Pglpg::VERSION)
  Pglpg.send(:remove_const, :VERSION)
  $LOADED_FEATURES.reject! { _1.end_with?("/lib/pglpg/version.rb") }
end
require "pglpg"
foreign = $LOADED_FEATURES.grep(%r{/lib/pglpg(\.rb|/)}).reject { _1.start_with?("#{lib}/") }
abort "library loaded outside requested path" if foreign.any?
require_relative "support/graph"
require_relative "support/fixture"
require_relative "support/cells"
require_relative "support/plan"

module TemporalBench
  TYPES = %w[KNOWS INVOLVED_IN MEMBER_OF FRIEND].freeze
  DATE = Date.new(2020, 6, 1).freeze
  # The 0.2 reference runs the same data/visibility/date eligibility through
  # its policy hook, using only its documented pre-temporal API.
  module ReferencePolicy
    def self.node(t, viewer) = BenchGraph::Policy.node(t, viewer)

    def self.edge(t, viewer)
      visibility = BenchGraph::Policy.edge(t, viewer)
      return visibility unless viewer.dated
      range = Arel::Nodes::NamedFunction.new("daterange", [t[:valid_from], t[:valid_to], Arel::Nodes.build_quoted("[)")])
      date = Arel::Nodes::NamedFunction.new("DATE", [Arel::Nodes.build_quoted(DATE.iso8601)])
      eligible = Arel::Nodes::InfixOperation.new("@>", range, date)
      visibility.and(t[:type].not_in(TYPES).or(eligible))
    end
  end
  Viewer = Data.define(:clearance, :dated)

  module_function

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def p95(values) = values.sort[[(values.size * 0.95).ceil - 1, 0].max]

  def fingerprint(result)
    data = if result.respond_to?(:complete?)
      [result.nodes.map { |ref, depth| [ref.to_s, depth] }, result.complete?, result.stopped_at_depth]
    elsif result.is_a?(Array)
      result.map { |row| row.transform_values { _1.ref.to_s } }
    else
      result
    end
    Digest::SHA256.hexdigest(JSON.generate(data))
  end
end

include TemporalBench
ActiveRecord::Base.establish_connection(ENV.fetch("PGLPG_BENCH_DATABASE_URL"))
c = ActiveRecord::Base.connection
Pglpg.configure do |conf|
  conf.max_rows = 10_000
  conf.statement_timeout = 30_000
end
plain = BenchGraph.define
g = opts[:baseline] ? BenchGraph.define(visibility: TemporalBench::ReferencePolicy) : BenchGraph.define(temporal: true)
manifest = { "fixture" => opts[:fixture], "generator" => Fixture::GENERATOR_VERSION,
             "active_percent" => opts[:active_percent], "date" => TemporalBench::DATE.iso8601,
             "temporal_types" => TemporalBench::TYPES }
if opts[:load]
  Fixture.load!(c, opts[:fixture], plain)
  types = TemporalBench::TYPES
  percent = opts[:active_percent]
  g.storage.enable_temporal!(types:, backfill: lambda { |db|
    db.execute(<<~SQL)
      UPDATE bench_edges SET
        valid_from = CASE WHEN id % 100 < #{percent} THEN DATE '2015-01-01'
                          WHEN id % 2 = 0 THEN DATE '2025-01-01' ELSE NULL END,
        valid_to = CASE WHEN id % 100 < #{percent} THEN DATE '2021-01-01'
                        WHEN id % 2 = 0 THEN NULL ELSE DATE '2019-01-01' END
      WHERE type IN ('KNOWS', 'INVOLVED_IN', 'MEMBER_OF', 'FRIEND')
    SQL
  })
  c.execute("DROP TABLE IF EXISTS temporal_bench_manifest")
  c.execute("CREATE TABLE temporal_bench_manifest (value jsonb)")
  c.execute("INSERT INTO temporal_bench_manifest VALUES (#{c.quote(manifest.to_json)}::jsonb)")
  c.execute("VACUUM ANALYZE bench_nodes")
  c.execute("VACUUM ANALYZE bench_edges")
end
saved = JSON.parse(c.select_value("SELECT value::text FROM temporal_bench_manifest"))
abort "temporal fixture mismatch: load it with the candidate first" unless saved == manifest
counts = c.select_rows("SELECT type, count(*), count(*) FILTER (WHERE daterange(valid_from,valid_to,'[)') @> DATE '2020-06-01') FROM bench_edges GROUP BY type ORDER BY type")
counts.each do |type, total, active|
  next unless TemporalBench::TYPES.include?(type)
  abort "no nontrivial dated workload for #{type}" unless active.positive? && active < total
end

out = opts[:out]
FileUtils.mkdir_p(out)
report = { "manifest" => manifest, "role" => opts[:baseline] ? "equivalent-policy-reference" : "candidate",
           "sha" => ENV["BENCH_SHA"] || `git -C #{lib} rev-parse HEAD 2>/dev/null`.strip,
           "library_digest" => Digest::SHA256.hexdigest(Dir[File.join(lib, "pglpg{.rb,/**/*.rb}")].sort.map { File.read(_1) }.join),
           "library" => lib, "version" => Pglpg::VERSION, "ruby" => RUBY_VERSION,
           "postgres" => c.select_value("SHOW server_version"), "counts" => counts, "configs" => {} }
reference = opts[:compare] && JSON.parse(File.read(File.join(opts[:compare], "results.json")))
abort "comparison manifest mismatch" if reference && reference["manifest"] != manifest
starts = [2, 4].to_h { [_1, Cells.starts(c, plain, _1)] }
selected = %w[hop1 hop2 hop3 hop3_hub sym1 sym2_hub reach_knows_depth2 reach_friend_overflow count2_hub]
cells = Cells.all(g).select { selected.include?(_1.id) }
cells << Cells.cell("incoming_hub", :knows_hub, ->(ctx, id) { ctx.match.node(:p, ref: g.ref(:node, id)).in(:KNOWS, :q).limit(500).to_a })
configs = opts[:baseline] ? %w[endpoint] : %w[endpoint composite covering gist]
failures = []
configs.each do |config|
  %w[source target gist].each { c.execute("DROP INDEX IF EXISTS bench_temporal_#{_1}") }
  case config
  when "composite", "covering"
    %w[source target].each do |near|
      far = near == "source" ? "target" : "source"
      keys = config == "composite" ? ", valid_from, valid_to" : ""
      payload = config == "covering" ? ", valid_from, valid_to" : ""
      c.execute("CREATE INDEX bench_temporal_#{near} ON bench_edges (#{near}_id, type#{keys}) INCLUDE (#{far}_id, classification#{payload})")
    end
  when "gist"
    c.execute("CREATE INDEX bench_temporal_gist ON bench_edges USING gist (daterange(valid_from, valid_to, '[)')) WHERE type IN ('KNOWS','INVOLVED_IN','MEMBER_OF','FRIEND')")
  end
  c.execute("ANALYZE bench_edges")
  config_result = { "cells" => {}, "indexes" => c.select_rows("SELECT indexrelname, pg_relation_size(indexrelid) FROM pg_stat_user_indexes WHERE relname = 'bench_edges' ORDER BY indexrelname") }
  report["configs"][config] = config_result
  [false, true].each do |dated|
    [2, 4].each do |clearance|
      ctx = if opts[:baseline]
        g.for(viewer: TemporalBench::Viewer.new(clearance:, dated:))
      else
        g.for(viewer: BenchGraph::Viewer.new(clearance), as_of: dated ? TemporalBench::DATE : :any)
      end
      cells.each do |cell|
        key = "#{dated ? 'dated' : 'any'}/#{cell.id}/L#{clearance}"
        row = { "errors" => [] }
        config_result["cells"][key] = row
        begin
          ids = starts[clearance].fetch(cell.starts)
          raise "no starts" if ids.empty?
          fingerprints = ids.to_h { |id| [id.to_s, TemporalBench.fingerprint(cell.run.call(ctx, id))] }
          sizes = ids.map { cell.size.call(cell.run.call(ctx, _1)) }
          raise "empty workload" unless sizes.sum.positive?
          row.merge!("fingerprints" => fingerprints, "rows" => sizes.sum, "nonempty" => sizes.count(&:positive?))
          expected = if reference
            reference.fetch("configs").fetch("endpoint").fetch("cells").fetch(key).fetch("fingerprints")
          else
            report.dig("configs", "endpoint", "cells", key, "fingerprints")
          end
          raise "result differs from endpoint/reference" if expected && fingerprints != expected
          samples = Array.new(Integer(ENV.fetch("TEMPORAL_BENCH_RUNS", "30"))) do |i|
            t = TemporalBench.clock
            cell.run.call(ctx, ids[i % ids.size])
            (TemporalBench.clock - t) * 1000
          end
          plans = ids.first(3).to_h do |id|
            statement, = Plan.capture { cell.run.call(ctx, id) }
            plan = Plan.explain(c, statement)
            [id.to_s, { "sql" => statement.sql, "binds" => statement.binds.map { _1.value.to_s }, "plan" => plan, "buffers" => Plan.buffers(plan) }]
          end
          slug = "#{config}_#{key.tr('/', '_')}"
          File.write(File.join(out, "#{slug}.json"), JSON.pretty_generate(plans))
          row.merge!("p95_ms" => TemporalBench.p95(samples).round(3), "buffers_p95" => TemporalBench.p95(plans.values.map { _1["buffers"] }), "samples_ms" => samples)
        rescue StandardError => e
          row["errors"] << "#{e.class}: #{e.message}"
          failures << "#{config}/#{key}: #{e.message}"
        end
      end
    end
  end
  # Same raw batch, rolled back: isolates index maintenance, not policy or
  # Ruby write throughput. Sequence increments are irrelevant to read starts.
  times = Array.new(5) do
    t = TemporalBench.clock
    c.transaction(requires_new: true) do
      c.execute("INSERT INTO bench_edges (type,source_id,target_id,classification,valid_from,valid_to) SELECT 'KNOWS', 1, 2, 1, DATE '2015-01-01', DATE '2021-01-01' FROM generate_series(1,1000)")
      raise ActiveRecord::Rollback
    end
    (TemporalBench.clock - t) * 1000
  end
  config_result["raw_1000_insert_p95_ms"] = TemporalBench.p95(times).round(3)
  File.write(File.join(out, "results.json"), JSON.pretty_generate(report))
  worst = config_result["cells"].values.filter_map { _1["p95_ms"] }.max
  puts "#{config}: #{config_result['cells'].size} cells, worst p95 #{worst} ms; insert batch p95 #{config_result['raw_1000_insert_p95_ms']} ms"
end
%w[source target gist].each { c.execute("DROP INDEX IF EXISTS bench_temporal_#{_1}") }
abort failures.join("\n") unless failures.empty?
