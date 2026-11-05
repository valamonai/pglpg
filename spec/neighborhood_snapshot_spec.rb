# frozen_string_literal: true

require "timeout"

RSpec.describe "neighborhood snapshot", :committed do
  it "keeps edges and their exact overflow flag at the traversal snapshot during a concurrent write" do
    a, b = person, person
    first = trusted.insert_edge(:KNOWS, from: a, to: b, attrs: { classification: 1 })
    connection = Kg.connection
    connection.execute(<<~SQL)
      CREATE FUNCTION pglpg_neighborhood_barrier(id bigint) RETURNS boolean LANGUAGE plpgsql AS $$
      BEGIN
        IF id = #{a.id} THEN PERFORM pg_advisory_xact_lock(725050); END IF;
        RETURN true;
      END
      $$
    SQL
    policy = Module.new do
      def self.node(table, viewer)
        barrier = Arel::Nodes::NamedFunction.new("pglpg_neighborhood_barrier", [table[:id]])
        ClearancePolicy.node(table, viewer).and(barrier.eq(true))
      end
      def self.edge(table, viewer) = ClearancePolicy.edge(table, viewer)
    end
    Pglpg.configuration.visibility = policy
    connection.execute("SELECT pg_advisory_lock(725050)")
    pid = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |c|
        pid << c.select_value("SELECT pg_backend_pid()")
        ctx(2).neighborhood(from: a, via: [:KNOWS], max_depth: 2, max_nodes: 2, max_edges: 1)
      end
    end
    backend = pid.pop
    Timeout.timeout(3) do
      until connection.select_value("SELECT wait_event FROM pg_stat_activity WHERE pid = #{backend}") == "advisory"
        sleep 0.01
      end
    end
    second = trusted.insert_edge(:KNOWS, from: b, to: a, attrs: { classification: 1 })
    connection.execute("SELECT pg_advisory_unlock(725050)")
    result = worker.value
    expect(result.nodes.map { |node, depth| [node.ref, depth] }).to eq([[a, 0], [b, 1]])
    expect(result.edges.map(&:ref)).to eq([first])
    expect(result.edges_truncated?).to be(false)
    after = ctx(2).neighborhood(from: a, via: [:KNOWS], max_depth: 2, max_nodes: 2, max_edges: 2)
    expect(after.edges.map(&:ref)).to eq([first, second])
    expect(ctx(2).neighborhood(from: a, via: [:KNOWS], max_depth: 2, max_nodes: 2, max_edges: 1).edges_truncated?).to be(true)
  ensure
    connection&.execute("SELECT pg_advisory_unlock_all()")
    worker&.join(6)
    connection&.execute("DROP FUNCTION IF EXISTS pglpg_neighborhood_barrier(bigint)")
  end
end
