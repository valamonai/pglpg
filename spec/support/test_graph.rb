# frozen_string_literal: true

Viewer = Data.define(:clearance)

# Rows are visible when their classification is at most the viewer's clearance.
module ClearancePolicy
  def self.node(table, viewer) = table[:classification].lteq(viewer.clearance)

  def self.edge(table, viewer) = table[:classification].lteq(viewer.clearance)
end

# Writers may only create, keep or move rows within their own clearance.
module ClearanceWritePolicy
  def self.authorize?(request)
    level = request.attrs[:classification]
    level.nil? || level <= request.viewer.clearance
  end

  # The stored row may not be above the writer's clearance either. (Visibility
  # already implies this; the extra condition exercises the hook.)
  def self.existing(table, request) = table[:classification].lteq(request.viewer.clearance)
end

Kg = Pglpg::Graph.define(:spec_kg) do
  column :classification, :integer, null: false, covering: true

  node :Agent, abstract: true do
    property :uid, :string, required: true
    key :uid
  end
  node :Person, extends: :Agent do
    property :name, :string
    property :rank, :integer
    property :born, :date
    property :tags, :list, of: :string
    property :status, :enum, values: %w[active retired]
  end
  node :Employee, extends: :Person do
    property :salary, :decimal
  end
  node :Project do
    property :uid, :string, required: true
    property :title, :string, required: true
    property :headcount, :integer
    property :started_at, :datetime
    key :uid
  end
  node :Location do
    property :uid, :string, required: true
    key :uid, generate: ->(_type) { "LOC-#{SecureRandom.hex(6)}" }
  end
  node :Note do
    property :text, :string
  end

  edge :WORKS_ON, from: :Person, to: :Project, unique: :pair do
    property :role, :string
    property :since, :date
  end
  edge :BASED_AT, from: :Project, to: :Location
  edge :KNOWS, from: :Person, to: :Person do
    property :weight, :float
  end
  edge :REVIEWED, from: :Person, to: :Project do
    property :score, :integer, required: true
  end
end

module TestGraph
  module_function

  def setup!
    Kg.storage.drop!
    Kg.storage.create!
  end

  def teardown!
    Kg.storage.drop!
  end

  def truncate!
    ActiveRecord::Base.connection.execute(
      "TRUNCATE #{Kg.edges_table}, #{Kg.nodes_table} RESTART IDENTITY"
    )
  end

  def configure!
    Pglpg.configure do |c|
      c.visibility = ClearancePolicy
      c.write_policy = ClearanceWritePolicy
      c.trusted_writer_allowed = ->(context) { context.viewer.clearance >= 3 }
    end
  end
end

module GraphHelpers
  def ctx(clearance = 4) = Kg.for(viewer: Viewer.new(clearance))

  def trusted(clearance = 4) = ctx(clearance).trusted_writer

  def person(level = 1, **props)
    trusted.insert_node(:Person, properties: { uid: "P-#{SecureRandom.hex(4)}", **props }, attrs: { classification: level })
  end

  def project(level = 1, **props)
    ctx.insert_node(:Project, properties: { title: "Project", **props }, attrs: { classification: level })
  end
end

RSpec.configure { _1.include GraphHelpers }
