# frozen_string_literal: true

require_relative "../bench/support/neighborhood_fixture"

RSpec.describe "the investigation neighborhood pilot" do
  before { NeighborhoodFixture::GRAPH.storage.create! }
  let(:fixture) { NeighborhoodFixture.load(incidents: 1, locations: 1) }
  let(:context) { NeighborhoodFixture.context }

  def observe(max_nodes: 3, max_edges: 2)
    r = context.neighborhood(from: fixture[:seed], via: NeighborhoodFixture::VIA,
                             max_depth: 2, max_nodes:, max_edges:)
    [r.nodes.map { |node, depth| [node.ref, depth] }, r.edges.map(&:ref),
     r.nodes_truncated?, r.edges_truncated?]
  end

  it "reproduces the analyst's two hops and exact node and edge truncation" do
    seed, incident, location = fixture[:seed], fixture[:incidents].first, fixture[:locations].first
    expect(observe).to eq([[[seed, 0], [incident, 1], [location, 2]], fixture[:edges], false, false])
    expect(observe(max_nodes: 2)).to eq([[[seed, 0], [incident, 1]], fixture[:edges].first(1), true, false])
    expect(observe(max_edges: 1)).to eq([[[seed, 0], [incident, 1], [location, 2]], fixture[:edges].first(1), false, true])
  end

  it "filters classified and retracted shortcuts before either overflow probe" do
    before = observe
    writer = fixture[:writer]
    shortcut = writer.insert_edge(:LOCATED_AT, from: fixture[:seed], to: fixture[:locations].first,
                       attrs: { classification: 3 })
    expect(observe).to eq(before)
    writer.update_edge(shortcut, attrs: { classification: 1, retracted_at: Time.now })
    expect(observe).to eq(before)
    expect(observe(max_edges: 0).last).to be(true)
  end
end
