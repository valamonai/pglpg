# frozen_string_literal: true

# Proposes bounds from measured results and writes them into bench/bounds.yml,
# replacing the bounds of the measured fixtures. Review the diff: bounds are a
# reviewed contract, and this only gives a starting point.
#
#   ruby bench/calibrate.rb tmp/bench/candidate [more result dirs…]
#
# Calibrate from CI results (the bench-<fixture> artifacts), not a laptop.
# latency_ms: LATENCY_FACTOR × p95, at least LATENCY_MIN_MS, and at most the
# 0.2 target of 500 ms for 3-hop shapes on 1m. buffers: BUFFER_FACTOR × p95,
# plus 10, which leaves room for a plan change on 10m, where ANALYZE still
# samples (bench/README.md). The relative gate, on one load and one set of
# statistics, catches smaller regressions. Workload minima: 80% of the rows
# returned; every hub and probe start must return rows.

require "json"
require "yaml"

LATENCY_FACTOR = Float(ENV.fetch("LATENCY_FACTOR", "3"))
LATENCY_MIN_MS = Integer(ENV.fetch("LATENCY_MIN_MS", "10"))
BUFFER_FACTOR = Float(ENV.fetch("BUFFER_FACTOR", "3"))
TARGET_MS = 500

def bound(fixture, cell)
  latency = [(cell.dig("latency_ms", "p95") * LATENCY_FACTOR).ceil, LATENCY_MIN_MS].max
  latency = [latency, TARGET_MS].min if fixture == "1m" && cell["shape"].start_with?("hop3")
  work = cell.fetch("workload")
  nonempty = cell["start_kind"] == "random" ? (work["nonempty"] * 0.8).floor : work["nonempty"]
  { "latency_ms" => latency, "buffers" => (cell.dig("buffers", "p95") * BUFFER_FACTOR).ceil + 10,
    "min_total" => (work["total"] * 0.8).floor, "min_nonempty" => nonempty }
end

path = File.expand_path("bounds.yml", __dir__)
bounds = YAML.safe_load_file(path)
ARGV.each do |dir|
  results = JSON.parse(File.read(File.join(dir, "results.json")))
  fixture = results.fetch("fixture")
  bounds["fixtures"][fixture] = results.fetch("cells").values.select { _1["status"] == "ok" }
                                       .group_by { _1["shape"] }
                                       .transform_values { |cells| cells.to_h { ["L#{_1["clearance"]}", bound(fixture, _1)] } }
end

# One line per viewer, so a bound change is a one-line diff.
text = File.read(path, encoding: "UTF-8")[/\A(?:#.*\n)*/]
text << "relative:\n" << bounds["relative"].map { "  #{_1}: #{_2}\n" }.join << "fixtures:\n"
bounds["fixtures"].each do |fixture, shapes|
  text << "  #{fixture}:\n"
  shapes.each do |shape, levels|
    text << "    #{shape}:\n"
    levels.each { |level, b| text << "      #{level}: {#{b.map { "#{_1}: #{_2}" }.join(", ")}}\n" }
  end
end
File.write(path, text)
