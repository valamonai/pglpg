# frozen_string_literal: true

# Proves the benchmark fails when it should. Takes real results, breaches
# them on purpose, and asserts that bench/gate.rb exits nonzero each time
# (and zero on the untouched results). Exits 1 if any assertion fails, so a
# gate that stopped failing turns CI red.
#
#   ruby bench/selftest.rb tmp/bench/candidate

require "json"
require "open3"
require "tmpdir"
require "yaml"
require_relative "support/plan"

dir = ARGV.fetch(0) { abort "usage: ruby bench/selftest.rb RESULTS_DIR" }
results = JSON.parse(File.read(File.join(dir, "results.json")))
# Bounds the results meet exactly, so the self-test doesn't depend on
# bench/bounds.yml (the gate step checks those).
exact = YAML.safe_load_file(File.expand_path("bounds.yml", __dir__)).merge("fixtures" => {
  results["fixture"] => results["cells"].values.select { _1["status"] == "ok" }.group_by { _1["shape"] }.transform_values do |cells|
    cells.to_h do |c|
      ["L#{c["clearance"]}", { "latency_ms" => c.dig("latency_ms", "p95"), "buffers" => c.dig("buffers", "p95"),
                               "min_total" => c.dig("workload", "total"), "min_nonempty" => c.dig("workload", "nonempty") }]
    end
  end
})
key, cell = results.fetch("cells").find { |_, c| c["status"] == "ok" && c.dig("buffers", "p95").positive? }
abort "no passing cell with buffers in #{dir}" unless cell
shape = cell["shape"]
level = "L#{cell["clearance"]}"
problems = []

gate = lambda do |name, results: nil, bounds: exact, baseline: nil, want:|
  Dir.mktmpdir do |tmp|
    args = ["--candidate", dir]
    if results
      FileUtils.mkdir_p(File.join(tmp, "c"))
      File.write(File.join(tmp, "c", "results.json"), JSON.generate(results))
      args = ["--candidate", File.join(tmp, "c")]
    end
    File.write(File.join(tmp, "bounds.yml"), bounds.to_yaml)
    args += ["--bounds", File.join(tmp, "bounds.yml")]
    if baseline
      FileUtils.mkdir_p(File.join(tmp, "b"))
      File.write(File.join(tmp, "b", "results.json"), JSON.generate(baseline))
      args += ["--baseline", File.join(tmp, "b")]
    end
    out, status = Open3.capture2e(RbConfig.ruby, File.expand_path("gate.rb", __dir__), *args)
    ok = want == :pass ? status.success? : status.exitstatus == 1 && out.include?(key)
    puts "#{ok ? "ok  " : "FAIL"} #{name}: gate exited #{status.exitstatus}"
    problems << "#{name}\n#{out}" unless ok
  end
end
copy = ->(obj) { JSON.parse(JSON.generate(obj)) }
breach = lambda do |field, value|
  b = copy.(exact)
  b["fixtures"][results["fixture"]][shape][level][field] = value
  b
end

gate.("untouched results pass", want: :pass)
gate.("latency bound breached", bounds: breach.("latency_ms", 0), want: :fail)
gate.("buffer bound breached", bounds: breach.("buffers", cell.dig("buffers", "p95") - 1), want: :fail)
gate.("workload minimum breached", bounds: breach.("min_total", cell.dig("workload", "total") + 1), want: :fail)
failed = copy.(results)
failed["cells"][key].merge!("status" => "failed", "errors" => ["timeout (30000 ms)"])
gate.("a failed cell", results: failed, want: :fail)
unbounded = copy.(exact)
unbounded["fixtures"][results["fixture"]][shape].delete(level)
gate.("a cell without a bound", bounds: unbounded, want: :fail)
cheaper = copy.(results).merge("sha" => "baseline")
cheaper["cells"][key]["buffers"]["p95"] = (cell.dig("buffers", "p95") / 2) - 10
gate.("buffers grew past the baseline", baseline: cheaper, want: :fail)

# Buffer extraction fails closed.
plan = [{ "Plan" => { "Node Type" => "Limit", "Shared Hit Blocks" => 7, "Shared Read Blocks" => 3 } }]
problems << "buffers of a full plan" unless Plan.buffers(plan) == 10
[
  ["no read blocks", [{ "Plan" => { "Shared Hit Blocks" => 7 } }]],
  ["no plan", []],
  ["text plan", ["Limit  (cost=0.42..8.44 rows=1 width=8)", "  Buffers: shared hit=3"]]
].each do |name, bad|
  Plan.buffers(bad)
  problems << "buffers of a plan with #{name} did not raise"
rescue Plan::Error
  puts "ok   buffers of a plan with #{name} raise"
end

if problems.any?
  warn "\nSELF-TEST FAILED\n#{problems.join("\n")}"
  exit 1
end
puts "self-test passed"
