# frozen_string_literal: true

# The benchmark graph: a clearance policy on every node and edge. Loaded by
# both the candidate and the baseline revision, so it only uses API that
# both have.
module BenchGraph
  Viewer = Data.define(:clearance)

  Policy = Module.new do
    def self.node(table, viewer) = table[:classification].lteq(viewer.clearance)
    def self.edge(table, viewer) = table[:classification].lteq(viewer.clearance)
  end

  CLEARANCES = [2, 4].freeze

  def self.define
    Pglpg::Graph.define(:bench, visibility: Policy) do
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
      edge :FRIEND, from: :Person, to: :Person, symmetric: true
    end
  end
end
