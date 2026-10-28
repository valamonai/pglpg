# frozen_string_literal: true

# Measures the SQL pglpg generates on a synthetic graph with hubs, with the
# visibility policy on every node and edge. See bench/README.md.
#
#   BENCH_SCALE=1 bundle exec ruby bench/run.rb     # ~200k nodes, ~1M edges
#   BENCH_SCALE=0.1 BENCH_MAX_P95_MS=50 bundle exec ruby bench/run.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "pglpg"

url = ENV.fetch("PGLPG_BENCH_DATABASE_URL", "postgres:///pglpg_bench")
scale = Float(ENV.fetch("BENCH_SCALE", "1"))
runs = Integer(ENV.fetch("BENCH_RUNS", "300"))
max_p95 = Float(ENV.fetch("BENCH_MAX_P95_MS", "500"))
max_buffers = Integer(ENV.fetch("BENCH_MAX_BUFFERS", "100000"))
reload = ENV["BENCH_RELOAD"] == "1"

ActiveRecord::Base.establish_connection(url)
conn = ActiveRecord::Base.connection

Viewer = Data.define(:clearance)
Policy = Module.new do
  def self.node(table, viewer) = table[:classification].lteq(viewer.clearance)
  def self.edge(table, viewer) = table[:classification].lteq(viewer.clearance)
end

Bench = Pglpg::Graph.define(:bench, visibility: Policy) do
  column :classification, :integer, null: false, covering: true
  node(:Person) do
    property :uid, :string, required: true
    property :name, :string
    key :uid
  end
  node(:Incident) { property :severity, :integer }
  node(:Location) { property :name, :string }
  node(:Organization) { property :name, :string }
  edge :KNOWS, from: :Person, to: :Person
  edge :INVOLVED_IN, from: :Person, to: :Incident
  edge :OCCURRED_AT, from: :Incident, to: :Location
  edge :MEMBER_OF, from: :Person, to: :Organization
end

counts = {
  persons: (120_000 * scale).round, incidents: (50_000 * scale).round,
  locations: (20_000 * scale).round, orgs: (10_000 * scale).round,
  knows: (391_000 * scale).round, involved: (300_000 * scale).round, member: (250_000 * scale).round
}
n = Bench.nodes_table
e = Bench.edges_table
level = "width_bucket(random(), ARRAY[0, 0.7, 0.85, 0.95]::float8[])" # 70% L1, 15% L2, 10% L3, 5% L4

loaded = conn.table_exists?(n) && conn.select_value("SELECT count(*) FROM #{n}").to_i ==
                                 counts.values_at(:persons, :incidents, :locations, :orgs).sum
if reload || !loaded
  puts "loading scale #{scale}…"
  Bench.storage.drop!
  Bench.storage.create!
  p_last = counts[:persons]
  i_first = p_last + 1
  i_last = p_last + counts[:incidents]
  l_first = i_last + 1
  l_last = i_last + counts[:locations]
  o_first = l_last + 1
  [
    "INSERT INTO #{n} (key_label, labels, properties, classification)
     SELECT 'Person', '{Person}', jsonb_build_object('uid', 'P' || g, 'name', 'person ' || g), #{level}
     FROM generate_series(1, #{counts[:persons]}) g",
    "INSERT INTO #{n} (key_label, labels, properties, classification)
     SELECT 'Incident', '{Incident}', jsonb_build_object('severity', 1 + (g % 5)), #{level}
     FROM generate_series(1, #{counts[:incidents]}) g",
    "INSERT INTO #{n} (key_label, labels, properties, classification)
     SELECT 'Location', '{Location}', jsonb_build_object('name', 'loc ' || g), #{level}
     FROM generate_series(1, #{counts[:locations]}) g",
    "INSERT INTO #{n} (key_label, labels, properties, classification)
     SELECT 'Organization', '{Organization}', jsonb_build_object('name', 'org ' || g), #{level}
     FROM generate_series(1, #{counts[:orgs]}) g",
    # Skewed sources (random()^2) create hubs.
    "INSERT INTO #{e} (type, source_id, target_id, classification)
     SELECT 'KNOWS', 1 + floor(random()^2 * #{p_last})::bigint, 1 + floor(random() * #{p_last})::bigint, #{level}
     FROM generate_series(1, #{counts[:knows]})",
    "INSERT INTO #{e} (type, source_id, target_id, classification)
     SELECT 'INVOLVED_IN', 1 + floor(random()^2 * #{p_last})::bigint,
            #{i_first} + floor(random() * #{counts[:incidents]})::bigint, #{level}
     FROM generate_series(1, #{counts[:involved]})",
    "INSERT INTO #{e} (type, source_id, target_id, classification)
     SELECT 'OCCURRED_AT', g, #{l_first} + floor(random() * #{counts[:locations]})::bigint, #{level}
     FROM generate_series(#{i_first}, #{i_last}) g",
    "INSERT INTO #{e} (type, source_id, target_id, classification)
     SELECT 'MEMBER_OF', 1 + floor(random()^2 * #{p_last})::bigint,
            #{o_first} + floor(random() * #{counts[:orgs]})::bigint, #{level}
     FROM generate_series(1, #{counts[:member]})",
    "ANALYZE #{n}", "ANALYZE #{e}"
  ].each { conn.execute(_1) }
end

Pglpg.configure do |c|
  c.statement_timeout = nil
  c.max_rows = 10_000
end

edges_total = conn.select_value("SELECT count(*) FROM #{e}").to_i
hub = conn.select_value("SELECT source_id FROM #{e} WHERE type = 'KNOWS' GROUP BY 1 ORDER BY count(*) DESC LIMIT 1").to_i
persons = counts[:persons]
rng = Random.new(42)
person = -> { Bench.ref(:node, 1 + rng.rand(persons)) }

shapes = {
  "find by key" => ->(g) { g.find_node(:Person, uid: "P#{1 + rng.rand(persons)}") },
  "1 hop: person → incidents" => ->(g) { g.match.node(:p, ref: person.()).out(:INVOLVED_IN, :i, :Incident).limit(500).to_a },
  "2 hops: person → incident → location" => lambda { |g|
    g.match.node(:p, ref: person.()).out(:INVOLVED_IN, :i, :Incident).out(:OCCURRED_AT, :l, :Location).limit(500).to_a
  },
  "3 hops: person → person → incident → location" => lambda { |g|
    g.match.node(:p, ref: person.()).out(:KNOWS, :q, :Person).out(:INVOLVED_IN, :i, :Incident)
     .out(:OCCURRED_AT, :l, :Location).limit(500).to_a
  },
  "3 hops from the largest hub" => lambda { |g|
    g.match.node(:p, ref: Bench.ref(:node, hub)).out(:KNOWS, :q, :Person).out(:INVOLVED_IN, :i, :Incident)
     .out(:OCCURRED_AT, :l, :Location).limit(500).to_a
  },
  "filtered 1 hop (severity ≥ 4)" => lambda { |g|
    g.match.node(:p, ref: person.()).out(:INVOLVED_IN, :i, :Incident).where(i: { severity: Pglpg.gte(4) }).limit(500).to_a
  },
  "count 2 hops from the hub" => lambda { |g|
    g.match.node(:p, ref: Bench.ref(:node, hub)).out(:KNOWS, :q, :Person).out(:MEMBER_OF, :o, :Organization).count
  }
}

def percentile(sorted, pct) = sorted[[(sorted.size * pct).ceil - 1, 0].max]

puts "\npglpg #{Pglpg::VERSION} · #{conn.select_value("SHOW server_version")} · " \
     "#{conn.select_value("SELECT count(*) FROM #{n}")} nodes · #{edges_total} edges · #{runs} runs per shape"
puts
puts "| Query shape | p50 L2 / L4 (ms) | p95 L2 / L4 (ms) | max (ms) |"
puts "|---|---|---|---|"
failures = []
shapes.each do |name, shape|
  stats = [2, 4].map do |clearance|
    g = Bench.for(viewer: Viewer.new(clearance))
    5.times { shape.(g) }
    times = Array.new(runs) do
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      shape.(g)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
    end.sort
    [percentile(times, 0.5), percentile(times, 0.95), times.last]
  end
  fmt = ->(v) { format("%.2f", v) }
  puts "| #{name} | #{fmt.(stats[0][0])} / #{fmt.(stats[1][0])} | #{fmt.(stats[0][1])} / #{fmt.(stats[1][1])} | " \
       "#{fmt.([stats[0][2], stats[1][2]].max)} |"
  worst = [stats[0][1], stats[1][1]].max
  failures << "#{name}: p95 #{fmt.(worst)} ms > #{max_p95} ms" if worst > max_p95
end

# Work, not just time: shared buffers touched by the hub query at L4.
g = Bench.for(viewer: Viewer.new(4))
plan = g.match.node(:p, ref: Bench.ref(:node, hub)).out(:KNOWS, :q, :Person).out(:INVOLVED_IN, :i, :Incident)
        .out(:OCCURRED_AT, :l, :Location).limit(500).explain(analyze: true, buffers: true)
buffers = plan.first(3).join[/Buffers: shared hit=(\d+)(?: read=(\d+))?/] ? ($1.to_i + $2.to_i) : 0
puts "\nhub 3-hop query, L4: #{buffers} shared buffers (limit #{max_buffers})"
failures << "hub 3-hop query touched #{buffers} buffers > #{max_buffers}" if buffers > max_buffers
if ENV["BENCH_PLAN"] == "1"
  puts "\n```", plan, "```"
end

if failures.any?
  warn "\nBENCHMARK FAILED\n  #{failures.join("\n  ")}"
  exit 1
end
