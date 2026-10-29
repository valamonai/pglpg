# frozen_string_literal: true

# Checks measured results against bench/bounds.yml, and optionally against a
# baseline revision measured on the same fixture. Prints a Markdown report
# and exits 1 when any check fails. See bench/README.md.
#
#   ruby bench/gate.rb --candidate tmp/bench/candidate                # absolute gate only
#   ruby bench/gate.rb --candidate tmp/bench/candidate --baseline tmp/bench/baseline
#   ruby bench/gate.rb ... --require-baseline   # an unavailable baseline, or one lacking an API, fails

require "json"
require "optparse"
require "yaml"

opts = { bounds: File.expand_path("bounds.yml", __dir__) }
OptionParser.new do |o|
  o.on("--candidate DIR") { opts[:candidate] = _1 }
  o.on("--baseline DIR") { opts[:baseline] = _1 }
  o.on("--bounds FILE") { opts[:bounds] = _1 }
  o.on("--require-baseline", "fail unless the baseline is available and supports every cell") { opts[:require_baseline] = true }
end.parse!

read = ->(dir) { JSON.parse(File.read(File.join(dir, "results.json"))) }
candidate = read.(opts.fetch(:candidate) { abort "--candidate is required" })
bounds = YAML.safe_load_file(opts[:bounds])
relative = bounds.fetch("relative")
failures = []
fail_with = ->(msg) { failures << msg }

abort "candidate results are unavailable: #{candidate["unavailable"]}" if candidate["unavailable"]
fixture = candidate.fetch("fixture")
declared = bounds.dig("fixtures", fixture) || {}

baseline = opts[:baseline] && File.exist?(File.join(opts[:baseline], "results.json")) ? read.(opts[:baseline]) : nil
baseline_note =
  if opts[:baseline].nil? then "not requested"
  elsif baseline.nil? then "unavailable: no baseline results"
  elsif baseline["unavailable"] then "unavailable: #{baseline["unavailable"]}"
  elsif baseline["sha"] == candidate["sha"] then "unavailable: baseline is the candidate (#{baseline["sha"]})"
  elsif baseline["fixture"] != fixture then "unavailable: baseline measured #{baseline["fixture"]}"
  end
compare = baseline_note.nil?
fail_with.("baseline #{baseline_note}") if opts[:require_baseline] && !compare

def fmt(value) = value.nil? ? "–" : (value.is_a?(Float) ? format("%.2f", value) : value.to_s)

rows = []
candidate.fetch("cells").each do |key, cell|
  shape = cell["shape"]
  level = "L#{cell["clearance"]}"
  bound = declared.dig(shape, level)
  verdicts = []
  case cell["status"]
  when "ok" then nil
  when "unsupported" then verdicts << "candidate lacks the API"
  else verdicts << "failed: #{Array(cell["errors"]).first(3).join("; ")}"
  end
  lat = cell.dig("latency_ms", "p95")
  buf = cell.dig("buffers", "p95")
  work = cell["workload"] || {}
  if bound.nil?
    verdicts << "no declared bound"
  elsif cell["status"] == "ok"
    verdicts << "p95 #{fmt(lat)} ms > #{bound["latency_ms"]} ms" if lat > bound.fetch("latency_ms")
    verdicts << "buffers #{buf} > #{bound["buffers"]}" if buf > bound.fetch("buffers")
    verdicts << "rows #{work["total"]} < #{bound["min_total"]}" if work["total"] < bound.fetch("min_total")
    if work["nonempty"] < bound.fetch("min_nonempty")
      verdicts << "non-empty starts #{work["nonempty"]} < #{bound["min_nonempty"]}"
    end
  end

  versus = "–"
  if compare
    # Both revisions run the same driver and cells, so a missing or failed
    # baseline cell is a broken measurement and always fails. Only a cell
    # whose API the baseline lacks is a note, unless --require-baseline.
    base = baseline.dig("cells", key)
    if base.nil?
      versus = "missing"
      verdicts << "no baseline measurement"
    elsif base["status"] == "unsupported"
      versus = "unsupported"
      verdicts << "baseline lacks the API" if opts[:require_baseline]
    elsif base["status"] != "ok"
      versus = "baseline failed"
      verdicts << "baseline failed: #{Array(base["errors"]).first(3).join("; ")}"
    elsif cell["status"] == "ok"
      base_buf = base.dig("buffers", "p95")
      allowed = [(base_buf * (1 + relative.fetch("buffer_allowance"))).floor, base_buf + relative.fetch("buffer_slack")].max
      verdicts << "buffers #{buf} > baseline #{base_buf} (allowed #{allowed})" if buf > allowed
      floor = relative.fetch("latency_floor_ms")
      ratio = [lat, floor].max / [base.dig("latency_ms", "p95"), floor].max
      verdicts << format("p95 %.1f× baseline > %.1f×", ratio, relative.fetch("latency_ratio")) if ratio > relative.fetch("latency_ratio")
      versus = format("%s buf · %.2f× p95", base_buf, ratio)
    end
  end

  verdicts.each { fail_with.("#{key}: #{_1}") }
  rows << [shape, level, cell["start_kind"], cell["starts"], fmt(lat), fmt(bound&.dig("latency_ms")), fmt(buf),
           fmt(bound&.dig("buffers")), "#{work["total"]} / #{work["nonempty"]}", versus,
           verdicts.empty? ? "✅" : "❌ #{verdicts.join("; ")}"]
end
measured = candidate["cells"].values.map { [_1["shape"], "L#{_1["clearance"]}"] }
declared.each do |shape, levels|
  levels.each_key { fail_with.("#{fixture}/#{shape}/#{_1}: declared but not measured") unless measured.include?([shape, _1]) }
end

stats = candidate["stats"]
puts "## Benchmark: #{fixture}"
puts
puts "- Candidate `#{candidate["sha"]}` · pglpg #{candidate["pglpg_version"]} · PostgreSQL #{candidate["server_version"]} · " \
     "#{candidate["elapsed_seconds"]} s"
puts "- Baseline: #{compare ? "`#{baseline["sha"]}` · #{baseline["elapsed_seconds"]} s" : baseline_note}"
puts "- Fixture v#{candidate.dig("manifest", "generator_version")} (seed #{candidate.dig("manifest", "seed")}, " \
     "storage #{candidate.dig("manifest", "storage")}): #{stats["nodes"].values.sum} nodes, " \
     "#{stats["edges"].values.sum} edges, top KNOWS out-degree #{stats["top_knows_out_degree"]}"
puts
puts "| Shape | Viewer | Starts | n | p95 ms | bound | buffers p95 | bound | rows / non-empty | vs baseline | |"
puts "|---|---|---|---|---|---|---|---|---|---|---|"
rows.each { puts "| #{_1.join(" | ")} |" }
puts
if failures.empty?
  puts "**Passed.**"
else
  puts "**Failed:**"
  failures.each { puts "- #{_1}" }
  exit 1
end
