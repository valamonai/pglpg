# frozen_string_literal: true

# Run with PGLPG_BENCH_DATABASE_URL on a dedicated disposable database.
require "fileutils"
require_relative "../lib/pglpg"
require_relative "support/plan"
require_relative "support/neighborhood_fixture"

ActiveRecord::Base.establish_connection(ENV.fetch("PGLPG_BENCH_DATABASE_URL"))
out = ARGV.fetch(0, "tmp/bench/neighborhood")
FileUtils.mkdir_p(out)
graph = NeighborhoodFixture::GRAPH
graph.storage.drop!
graph.storage.create!

def reference(context, fixture, max_nodes:, max_edges:)
  reach = context.reachable(from: fixture[:seed], via: NeighborhoodFixture::VIA,
                            max_depth: 2, max_nodes: max_nodes - 1)
  selected = [fixture[:seed], *reach.nodes.map(&:first)]
  node_values = { fixture[:seed] => context.find(fixture[:seed]) }
  queries = [[fixture[:seed], :INVOLVED_IN], [fixture[:seed], :LOCATED_AT]]
  queries.concat(fixture[:incidents].select { selected.include?(_1) }.map { [_1, :OCCURRED_AT] })
  edges = queries.flat_map do |source, type|
    context.match.node(:s, ref: source).out(type, :t, edge: :e).return(:s, :t, :e).map do |row|
      node_values[row[:s].ref] = row[:s]
      node_values[row[:t].ref] = row[:t]
      row[:e]
    end
  end.select { selected.include?(_1.source) && selected.include?(_1.target) }.sort_by(&:id)
  nodes = [[node_values.fetch(fixture[:seed]), 0]] +
          reach.nodes.map { |ref, depth| [node_values.fetch(ref), depth] }
  Pglpg::Neighborhood.new(nodes:, edges: edges.first(max_edges),
                         nodes_truncated: !reach.complete?, edges_truncated: edges.size > max_edges)
end

def observe(result)
  [result.nodes.map { |node, depth| [node.ref, depth, node.properties, node.attrs] },
   result.edges.map { |edge| [edge.ref, edge.source, edge.target, edge.properties, edge.attrs] },
   result.nodes_truncated?, result.edges_truncated?]
end

def measure(call)
  5.times { call.call }
  samples = Array.new(30) do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    call.call
    1000 * (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
  end.sort
  { p50_ms: samples[14], p95_ms: samples[28] }
end

results = {}
[
  ["pilot", 100, 121, 200, false],
  ["fanout", 500, 21, 10, false],
  ["dense", 100, 121, 20, true]
].each do |name, count, node_cap, edge_cap, dense|
  graph.connection.transaction do
    fixture = NeighborhoodFixture.load(incidents: count)
    if dense
      fixture[:incidents].each_with_index do |incident, index|
        fixture[:locations].each_with_index do |location, place|
          next if place == index % fixture[:locations].size

          fixture[:edges] << fixture[:writer].insert_edge(:OCCURRED_AT, from: incident, to: location, attrs: { classification: 1 })
        end
      end
    end
    graph.connection.execute("ANALYZE #{graph.nodes_table}")
    graph.connection.execute("ANALYZE #{graph.edges_table}")
    context = NeighborhoodFixture.context
    candidate = -> { context.neighborhood(from: fixture[:seed], via: NeighborhoodFixture::VIA,
                                         max_depth: 2, max_nodes: node_cap, max_edges: edge_cap) }
    baseline = -> { reference(context, fixture, max_nodes: node_cap, max_edges: edge_cap) }
    expected = baseline.call
    raise "#{name}: result mismatch" unless observe(candidate.call) == observe(expected)

    statement, result = Plan.capture { candidate.call }
    full_nodes = [[fixture[:seed], 0]] + fixture[:incidents].map { [_1, 1] } +
                 fixture[:locations].map { [_1, 2] }
    selected = full_nodes.first(node_cap)
    selected_refs = selected.map(&:first)
    visible_edges = fixture[:edges].select do |ref|
      edge = context.find(ref)
      selected_refs.include?(edge.source) && selected_refs.include?(edge.target)
    end.sort_by(&:id)
    expected_work = [selected, visible_edges.first(edge_cap), full_nodes.size > node_cap, visible_edges.size > edge_cap]
    actual_work = [result.nodes.map { |node, depth| [node.ref, depth] }, result.edges.map(&:ref),
                   result.nodes_truncated?, result.edges_truncated?]
    raise "#{name}: workload mismatch" unless actual_work == expected_work
    statements = []
    callback = lambda do |*, payload|
      statements << Plan::Statement.new(payload[:sql], payload[:binds]) if payload[:name] == "Pglpg"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { baseline.call }
    row = { visible_incidents: count, hidden_incidents: count, visible_locations: 20,
            max_nodes: node_cap, max_edges: edge_cap, returned_nodes: result.nodes.size,
            returned_edges: result.edges.size, nodes_truncated: result.nodes_truncated?,
            edges_truncated: result.edges_truncated? }
    row[:candidate] = measure(candidate).merge(data_statements: 1)
    row[:reference] = measure(baseline).merge(data_statements: statements.size)
    plans = [statement, *statements].map { Plan.explain(graph.connection, _1) }
    row[:candidate][:shared_buffers] = Plan.buffers(plans.first)
    row[:reference][:shared_buffers] = plans.drop(1).sum { Plan.buffers(_1) }
    File.write(File.join(out, "#{name}-plans.json"), JSON.pretty_generate(plans))
    sql = [statement, *statements].map do |query|
      { sql: query.sql, binds: query.binds.map(&:value_for_database) }
    end
    File.write(File.join(out, "#{name}-statements.json"), JSON.pretty_generate(sql))
    results[name] = row
    puts "#{name}: #{JSON.generate(row)}"
    raise ActiveRecord::Rollback
  end
end
metadata = { revision: IO.popen(["git", "rev-parse", "HEAD"], &:read).strip, ruby: RUBY_VERSION, active_record: ActiveRecord.version.to_s,
             postgres: graph.connection.select_value("SHOW server_version"),
             warmups: 5, samples: 30, cache: "warm", results: }
File.write(File.join(out, "results.json"), JSON.pretty_generate(metadata))
graph.storage.drop!
