# frozen_string_literal: true

RSpec.describe "neighborhood temporal eligibility" do
  let(:graph) do
    Pglpg::Graph.define(:neighborhood_dates) do
      column :classification, :integer, null: false
      node :P
      edge :T, from: :P, to: :P, temporal: true
      edge :N, from: :P, to: :P
    end
  end

  it "filters expired and future edges before depth, edge ordering and exact probes" do
    graph.storage.create!
    writer = graph.for(viewer: Viewer.new(4)).trusted_writer
    a, b, c = Array.new(3) { writer.insert_node(:P, attrs: { classification: 1 }) }
    edge = ->(s, t, **validity) { writer.insert_edge(:T, from: s, to: t, attrs: { classification: 1 }, **validity) }
    edge.call(a, c, valid_from: nil, valid_to: Date.new(2020, 6, 1))
    first = edge.call(a, b, valid_from: Date.new(2020, 6, 1))
    second = writer.insert_edge(:N, from: b, to: c, attrs: { classification: 1 })
    edge.call(c, a, valid_from: Date.new(2020, 6, 2))
    context = graph.for(viewer: Viewer.new(2), as_of: Date.new(2020, 6, 1))
    r = context.neighborhood(from: a, via: %i[T N], max_depth: 2, max_nodes: 3, max_edges: 2)
    expect(r.nodes.map { |n, depth| [n.ref, depth] }).to eq([[a, 0], [b, 1], [c, 2]])
    expect(r.edges.map(&:ref)).to eq([first, second])
    expect([r.nodes_truncated?, r.edges_truncated?]).to eq([false, false])
    any = graph.for(viewer: Viewer.new(2), as_of: :any)
    expect(any.neighborhood(from: a, via: %i[T N], max_depth: 2, max_nodes: 3, max_edges: 2).edges_truncated?).to be(true)
    expect {
      graph.for(viewer: Viewer.new(2)).neighborhood(from: a, via: [:T], max_depth: 1, max_nodes: 1, max_edges: 0)
    }.to raise_error(Pglpg::TemporalModeRequired)
  end
end
