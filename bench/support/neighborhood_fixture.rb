# frozen_string_literal: true

# Synthetic investigation workload used by the neighborhood specs and benchmark.
module NeighborhoodFixture
  Viewer = Data.define(:clearance)

  module Policy
    def self.node(table, viewer) = table[:classification].lteq(viewer.clearance)
    def self.edge(table, viewer)
      table[:classification].lteq(viewer.clearance).and(table[:retracted_at].eq(nil))
    end
  end

  module Writes
    def self.authorize?(_request) = true
  end

  GRAPH = Pglpg::Graph.define(:neighborhood_fixture, visibility: Policy, write_policy: Writes,
                              trusted_writer_allowed: ->(_context) { true }) do
    column :classification, :integer, null: false
    edge_column :retracted_at, :datetime
    node(:Person) { property :name, :string }
    node(:Incident) { property :name, :string }
    node(:Location) { property :name, :string }
    edge :INVOLVED_IN, from: :Person, to: :Incident, unique: :pair
    edge :OCCURRED_AT, from: :Incident, to: :Location, unique: :pair
    edge :LOCATED_AT, from: :Person, to: :Location, unique: :pair
  end
  VIA = %i[INVOLVED_IN OCCURRED_AT LOCATED_AT].freeze

  def self.context = GRAPH.for(viewer: Viewer.new(2))

  def self.load(incidents: 100, locations: 20)
    writer = GRAPH.for(viewer: Viewer.new(4)).trusted_writer
    node = ->(type, level, name) { writer.insert_node(type, properties: { name: }, attrs: { classification: level }) }
    seed = node.call(:Person, 1, "Investigator's starting person")
    places = Array.new(locations) { |i| node.call(:Location, 1, "Location #{i}") }
    visible = Array.new(incidents) { |i| node.call(:Incident, 2, "Incident #{i}") }
    hidden = Array.new(incidents) { |i| node.call(:Incident, 3, "Classified incident #{i}") }
    visible_edges = []
    (visible + hidden).each_with_index do |incident, i|
      links = [
        writer.insert_edge(:INVOLVED_IN, from: seed, to: incident, attrs: { classification: 1 }),
        writer.insert_edge(:OCCURRED_AT, from: incident, to: places.fetch(i % locations), attrs: { classification: 1 })
      ]
      visible_edges.concat(links) if i < incidents
    end
    { seed:, incidents: visible, hidden:, locations: places, edges: visible_edges, writer: }
  end
end
