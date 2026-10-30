# frozen_string_literal: true

# Shared leak specs for an application's visibility policy.
#
#   require "pglpg/testing"
#
#   RSpec.describe MyApp::ClearancePolicy do
#     it_behaves_like "a pglpg visibility policy" do
#       let(:pglpg_visibility)    { MyApp::ClearancePolicy }
#       let(:pglpg_viewer)        { MyApp::Viewer.new(clearance: 2) }
#       let(:pglpg_columns)       { { classification: [:integer, { null: false }] } }
#       let(:pglpg_visible_attrs) { { classification: 1 } }  # visible to the viewer
#       let(:pglpg_hidden_attrs)  { { classification: 4 } }  # hidden from the viewer
#     end
#   end
#
# The suite builds its own small graph with the given application columns in
# temporary tables, inside a transaction that is rolled back. It is
# metamorphic: it records what the viewer can observe on a visible fixture,
# adds hidden nodes and edges (hidden bridges, hidden edges between visible
# nodes, visible edges to hidden nodes), and checks that every observation
# (rows, order, counts, exists?, first, pagination, lookups) is unchanged.
# Execution time and timeouts are outside this guarantee.
RSpec.shared_examples "a pglpg visibility policy" do
  leak_graph = lambda do |visibility, columns|
    Pglpg::Graph.define(:pglpg_leak, nodes_table: "pglpg_leak_nodes", edges_table: "pglpg_leak_edges",
                                     visibility:, write_policy: Pglpg::Testing::AllowAll,
                                     trusted_writer_allowed: ->(_context) { true }) do
      columns.each { |name, (type, options)| column(name, type, **(options || {})) }
      node :Person do
        property :uid, :string, required: true
        property :name, :string
        property :rank, :integer
        key :uid
      end
      node :Project do
        property :uid, :string, required: true
        property :title, :string
        key :uid
      end
      node :Location do
        property :uid, :string, required: true
        key :uid
      end
      edge :WORKS_ON, from: :Person, to: :Project do
        property :role, :string
      end
      edge :BASED_AT, from: :Project, to: :Location
      edge :KNOWS, from: :Person, to: :Person
      edge :FRIEND, from: :Person, to: :Person, symmetric: true
    end
  end

  around do |example|
    ActiveRecord::Base.transaction(requires_new: true) do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  let(:pglpg_leak_graph) { leak_graph.call(pglpg_visibility, pglpg_columns) }
  let(:pglpg_seed_graph) { leak_graph.call(Pglpg::Testing::SeeAll, pglpg_columns) }

  it "keeps every observation unchanged when hidden data is added" do
    pglpg_leak_graph.storage.create!
    seed = pglpg_seed_graph.for(viewer: nil).trusted_writer
    vis = pglpg_visible_attrs
    hid = pglpg_hidden_attrs
    person = ->(uid, name, rank, attrs) { seed.insert_node(:Person, properties: { uid:, name:, rank: }, attrs:) }
    node = ->(type, uid, attrs, **props) { seed.insert_node(type, properties: { uid:, **props }, attrs:) }
    edge = ->(type, from, to, attrs, **props) { seed.insert_edge(type, from:, to:, properties: props, attrs:) }

    # Created first, so it has the smallest id: symmetric edges to it are
    # stored with the hidden node in the source column.
    h0 = person.("H0", "Abe", 0, hid)
    p1 = person.("P1", "Ann", 1, vis)
    p2 = person.("P2", "Bob", 2, vis)
    p3 = person.("P3", "Cid", 3, vis)
    j1 = node.(:Project, "J1", vis, title: "Apollo")
    j2 = node.(:Project, "J2", vis, title: "Gemini")
    l1 = node.(:Location, "L1", vis)
    visible_edges = [
      edge.(:WORKS_ON, p1, j1, vis, role: "lead"),
      edge.(:WORKS_ON, p2, j1, vis, role: "dev"),
      edge.(:WORKS_ON, p3, j2, vis, role: "lead"),
      edge.(:BASED_AT, j1, l1, vis),
      edge.(:KNOWS, p1, p2, vis),
      edge.(:KNOWS, p2, p3, vis),
      edge.(:FRIEND, p2, p1, vis),
      edge.(:FRIEND, p3, p2, vis)
    ]
    visible_refs = [p1, p2, p3, j1, j2, l1, *visible_edges]

    ctx = pglpg_leak_graph.for(viewer: pglpg_viewer)
    before = Pglpg::Testing.observe(ctx, visible_refs)
    if before[:persons].size != 3 || before[:works_on].size != 3
      raise "the visibility policy hides the visible fixture; check pglpg_visible_attrs"
    end

    h1 = person.("H1", "Ann", 1, hid)
    h2 = person.("H2", "Zed", 5, hid)
    hj = node.(:Project, "HJ", hid, title: "Apollo")
    hl = node.(:Location, "HL", hid)
    hidden_refs = [
      h0, h1, h2, hj, hl,
      # symmetric edges: hidden between visible nodes, and visible ones through
      # hidden nodes stored at either end (a hidden bridge p1 ~ h0 ~ p3)
      edge.(:FRIEND, p3, p1, hid),
      edge.(:FRIEND, p1, h0, vis),
      edge.(:FRIEND, h0, p3, vis),
      edge.(:FRIEND, p2, h1, vis),
      # hidden edges between visible nodes
      edge.(:WORKS_ON, p3, j1, hid, role: "lead"),
      edge.(:KNOWS, p3, p1, hid),
      edge.(:BASED_AT, j2, l1, hid),
      # visible edges touching hidden nodes, including a hidden bridge p3 -> h1 -> p1
      edge.(:WORKS_ON, p1, hj, vis, role: "lead"),
      edge.(:BASED_AT, j2, hl, vis),
      edge.(:KNOWS, p3, h1, vis),
      edge.(:KNOWS, h1, p1, vis),
      edge.(:KNOWS, h2, p2, vis),
      edge.(:WORKS_ON, h2, j2, vis, role: "dev"),
      # hidden edge between hidden nodes
      edge.(:KNOWS, h1, h2, hid)
    ]

    after = Pglpg::Testing.observe(ctx, visible_refs)
    before.each_key { |name| expect(after[name]).to eq(before[name]), "observation #{name} changed" }

    hidden_refs.each { |ref| expect(ctx.find(ref)).to be_nil, "#{ref} is visible" }
    expect(ctx.find_node(:Person, uid: "H1")).to be_nil

    models = Pglpg::Testing.leak_models(pglpg_leak_graph)
    [h0, h1, h2].each do |ref|
      expect { models[:Person].in(ctx).find(ref) }.to raise_error(Pglpg::Model::RecordNotFound), "#{ref} is visible"
    end
    expect { models[:Project].in(ctx).find(hj) }.to raise_error(Pglpg::Model::RecordNotFound), "#{hj} is visible"
  end
end
