# frozen_string_literal: true

RSpec.describe "bounded neighborhoods" do
  let!(:a) { person(1, name: "A") }
  let!(:b) { person(1, name: "B") }
  let!(:c) { person(1, name: "C") }
  let!(:d) { person(1, name: "D") }

  def edge(from, to, type: :KNOWS, level: 1)
    trusted.insert_edge(type, from:, to:, attrs: { classification: level })
  end

  def neighborhood(from = a, **options)
    ctx(2).neighborhood(from:, via: [:KNOWS], max_depth: 3, max_nodes: 10, max_edges: 10, **options)
  end

  def observations(result)
    [result.nodes.map { |node, depth| [node.ref, depth] }, result.edges.map(&:ref),
     result.nodes_truncated?, result.edges_truncated?]
  end

  it "returns typed, frozen nodes and induced edges including reverse edges and parallel edges" do
    links = [edge(a, b), edge(b, c), edge(c, a), edge(a, b)]
    result = neighborhood
    expect(result.nodes.map { |node, depth| [node.ref, depth] }).to eq([[a, 0], [b, 1], [c, 2]])
    expect(result.nodes.first.first.properties[:name]).to eq("A")
    expect(result.edges.map(&:ref)).to eq(links)
    expect(result.edges[2].source).to eq(c)
    expect(result.edges[2].target).to eq(a)
    expect(result.nodes_truncated?).to be(false)
    expect(result.edges_truncated?).to be(false)
    expect([result, result.nodes, result.nodes.first, result.nodes.first.first, result.edges, result.edges.first])
      .to all(be_frozen)
  end

  it "matches a reference at every node and edge cap around an exact boundary" do
    links = [[a, b], [a, c], [b, d], [c, d], [d, a]].map { |s, t| [s, t, edge(s, t)] }
    full = [[a, 0], [b, 1], [c, 1], [d, 2]]
    (1..5).each do |node_cap|
      (0..6).each do |edge_cap|
        selected = full.first(node_cap)
        ids = selected.map(&:first)
        induced = links.select { |s, t, _| ids.include?(s) && ids.include?(t) }.map(&:last)
        expect(observations(neighborhood(max_nodes: node_cap, max_edges: edge_cap)))
          .to eq([selected, induced.first(edge_cap), full.size > node_cap, induced.size > edge_cap])
      end
    end
  end

  it "probes a seed-only selection and ignores edges to omitted nodes for edge truncation" do
    expect(observations(neighborhood(max_nodes: 1, max_edges: 0))).to eq([[[a, 0]], [], false, false])
    edge(a, b)
    expect(observations(neighborhood(max_nodes: 1, max_edges: 0))).to eq([[[a, 0]], [], true, false])
    loop_ref = edge(a, a, type: :SAME_AS)
    result = neighborhood(via: %i[KNOWS SAME_AS], max_nodes: 1, max_edges: 0)
    expect([result.nodes_truncated?, result.edges_truncated?]).to eq([true, true])
    expect(neighborhood(via: %i[KNOWS SAME_AS], max_nodes: 1).edges.map(&:ref)).to eq([loop_ref])
  end

  [:out, :in, :both].each do |direction|
    it "follows symmetric types in both directions with #{direction}" do
      links = [edge(b, a, type: :FRIEND), edge(b, c, type: :FRIEND)]
      result = neighborhood(c, via: [:FRIEND], direction:)
      expect(result.nodes.map { |node, depth| [node.ref, depth] }).to eq([[c, 0], [b, 1], [a, 2]])
      expect(result.edges.map(&:ref)).to eq(links)
    end
  end

  it "mixes directed and symmetric types and respects directed traversal" do
    links = [edge(a, b), edge(c, b, type: :FRIEND), edge(d, c)]
    expect(neighborhood(via: %i[KNOWS FRIEND]).nodes.map { _1.first.ref }).to eq([a, b, c])
    expect(neighborhood(via: %i[KNOWS FRIEND], direction: :both).nodes.map { _1.first.ref }).to eq([a, b, c, d])
    expect(neighborhood(c, via: %i[KNOWS FRIEND], direction: :in).nodes.map { _1.first.ref }).to eq([c, b, d, a])
    expect(neighborhood(via: %i[KNOWS FRIEND], direction: :both).edges.map(&:ref)).to eq(links)
  end

  it "applies the same allow-list to edges and limits completeness to the requested depth" do
    first = edge(a, b)
    edge(b, c)
    edge(a, b, type: :MET)
    result = neighborhood(max_depth: 1, max_nodes: 2, max_edges: 1)
    expect(observations(result)).to eq([[[a, 0], [b, 1]], [first], false, false])
  end

  it "makes missing and hidden seeds identical and validates budgets and refs before reading" do
    hidden = person(4)
    missing = Kg.ref(:node, 9_999_999)
    expect(observations(neighborhood(hidden))).to eq(observations(neighborhood(missing)))
    expect(observations(neighborhood(hidden))).to eq([[], [], false, false])
    [{ max_depth: 0 }, { max_depth: 1.5 }, { max_nodes: 0 }, { max_nodes: 1001 },
     { max_edges: -1 }, { max_edges: 1001 }, { max_edges: 1.5 }, { via: [] },
     { via: [:UNKNOWN] }, { direction: :sideways }, { deadline: 0 }].each do |options|
      expect { neighborhood(**options) }.to raise_error(ArgumentError)
    end
    expect { neighborhood(edge(a, b)) }.to raise_error(Pglpg::InvalidRef)
  end

  it "issues one data statement including hydration and restores the timeout" do
    edge(a, b)
    connection = Kg.connection
    before = connection.select_value("SHOW statement_timeout")
    reads = []
    callback = ->(*args) { reads << args.last[:sql] if args.last[:name] == "Pglpg" }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { neighborhood(deadline: 0.5) }
    expect(result.nodes.size).to eq(2)
    expect(reads.size).to eq(1)
    expect(connection.select_value("SHOW statement_timeout")).to eq(before)
  end

  it "restores the caller transaction after a statement timeout" do
    slow = Module.new do
      def self.node(table, viewer)
        ClearancePolicy.node(table, viewer).and(Arel.sql("(SELECT true FROM pg_sleep(0.05))"))
      end
      def self.edge(table, viewer) = ClearancePolicy.edge(table, viewer)
    end
    Pglpg.configuration.visibility = slow
    expect {
      ctx(2).neighborhood(from: a, via: [:KNOWS], max_depth: 1,
                                                 max_nodes: 2, max_edges: 1, deadline: 0.001)
    }.to raise_error(Pglpg::QueryTimeout)
    Pglpg.configuration.visibility = ClearancePolicy
    expect(neighborhood.nodes.size).to eq(1)
  end
end
