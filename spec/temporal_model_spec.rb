# frozen_string_literal: true

RSpec.describe "temporal models and associations" do
  let(:graph) do
    Pglpg::Graph.define(:temporal_models) do
      column :classification, :integer, null: false
      node(:P) { property :name, :string }
      edge :T, from: :P, to: :P, temporal: true
      edge :S, from: :P, to: :P, temporal: true, symmetric: true
      edge :N, from: :P, to: :P
    end
  end
  let(:node_model) do
    g = graph
    Class.new(Pglpg::Model::Node) do
      graph g, type: :P
      has_many :related, :out, edge: :T
      has_many :incoming, :in, edge: :T
      has_many :friends, :both, edge: :S
    end
  end
  let(:edge_model) { g = graph; Class.new(Pglpg::Model::Edge) { graph g, type: :T } }
  let(:plain_model) { g = graph; Class.new(Pglpg::Model::Edge) { graph g, type: :N } }
  let(:any) { graph.for(viewer: Viewer.new(2), as_of: :any) }
  let(:dated) { graph.for(viewer: Viewer.new(2), as_of: Date.new(2020, 1, 1)) }
  let(:writer) { graph.for(viewer: Viewer.new(4)).trusted_writer }
  let(:a) { writer.insert_node(:P, properties: { name: "A" }, attrs: { classification: 1 }) }
  let(:b) { writer.insert_node(:P, properties: { name: "B" }, attrs: { classification: 1 }) }

  before { graph.storage.create! }

  def bound_record(context = any, **attributes)
    edge_model.in(context).new(source: a, target: b, classification: 1, **attributes)
  end

  it "requires explicit lower-bound assignment, including constructor/setter nil-to-nil" do
    record = bound_record
    expect(record.save).to be(false)
    expect(record.errors[:valid_from]).not_to be_empty
    record.valid_from = nil
    expect(record.save!).to be(true)
    expect(record.reload.valid_from).to be_nil
    expect(record).not_to be_changed
    expect(bound_record(valid_from: nil).save!).to be(true)
    expect(plain_model.attribute_names).not_to include("valid_from", "valid_to")
    expect { plain_model.in(any).new(valid_from: nil) }.to raise_error(ActiveModel::UnknownAttributeError)
    expect { plain_model.in(any).new.valid_to = nil }.to raise_error(NoMethodError)
  end

  it "rejects coerced bounds and preserves invalid/failed assignments for correction" do
    record = bound_record(valid_from: nil)
    ["2020-01-01", DateTime.new(2020), Time.utc(2020)].each do |bad|
      expect { record.valid_from = bad }.to raise_error(Pglpg::ValidationError)
    end
    record.valid_from = Date.new(2020, 1, 2)
    record.valid_to = Date.new(2020, 1, 1)
    expect(record.save).to be(false)
    expect(record.valid_from).to eq(Date.new(2020, 1, 2))
    record.valid_to = nil
    expect(record.save!).to be(true)
    record.valid_to = Date.new(2021, 1, 1)
    expect(record.save!).to be(true)
    expect(record.reload.valid_to).to eq(Date.new(2021, 1, 1))
  end

  it "hydrates bounds, plucks them and filters all edge relation terminals" do
    active = bound_record(valid_from: nil).tap(&:save!)
    old = bound_record(valid_from: nil, valid_to: Date.new(2020, 1, 1)).tap(&:save!)
    relation = edge_model.in(dated)
    expect(relation.count).to eq(1)
    expect(relation.exists?).to be(true)
    expect(relation.pluck(:ref, :valid_from)).to eq([[active.ref, nil]])
    expect(relation.first.ref).to eq(active.ref)
    expect { relation.find(old.ref) }.to raise_error(Pglpg::Model::RecordNotFound)
    expect { edge_model.in(any).find(old.ref).tap { _1.instance_variable_set(:@context, dated) }.reload }.to raise_error(Pglpg::Model::RecordNotFound)
    expect(edge_model.in(any).find(active.ref)).not_to be_changed
  end

  it "refuses no-op/changed saves and creates on Date contexts before validation or authorization" do
    record = bound_record(valid_from: nil).tap(&:save!)
    read = edge_model.in(dated).find(record.ref)
    expect(ClearanceWritePolicy).not_to receive(:authorize?)
    expect(read).not_to receive(:valid?)
    expect { read.save }.to raise_error(Pglpg::ReadOnlyContext)
    expect { read.save! }.to raise_error(Pglpg::ReadOnlyContext)
    expect { read.destroy }.to raise_error(Pglpg::ReadOnlyContext)
    expect { bound_record(dated, valid_from: nil).save }.to raise_error(Pglpg::ReadOnlyContext)
    expect { node_model.in(dated).create!(name: "X", classification: 1) }.to raise_error(Pglpg::ReadOnlyContext)
  end

  it "propagates the dated context through lazy, nested eager, incoming and binding reads" do
    edge_model
    c = writer.insert_node(:P, properties: { name: "C" }, attrs: { classification: 1 })
    writer.insert_edge(:T, from: a, to: b, valid_from: nil, attrs: { classification: 1 })
    writer.insert_edge(:T, from: b, to: c, valid_from: Date.new(2021, 1, 1), attrs: { classification: 1 })
    writer.insert_edge(:T, from: a, to: c, valid_from: nil, valid_to: Date.new(2020, 1, 1), attrs: { classification: 1 })
    writer.insert_edge(:T, from: a, to: c, valid_from: nil, attrs: { classification: 3 })
    owner = node_model.in(dated).find(a)
    expect(owner.related.pluck(:ref)).to eq([b])
    expect(owner.related.with_rel.pluck(:ref, rel: :valid_from)).to eq([[b, nil]])
    eager = node_model.in(dated).with_associations(related: :related).to_a.find { _1.ref == a }
    expect(eager.related.map(&:ref)).to eq([b])
    expect(eager.related.first.related.to_a).to eq([])
    expect(eager.related.first.context).to equal(dated)
    expect(node_model.in(dated).find(b).incoming.pluck(:ref)).to eq([a])
    writer.insert_edge(:T, from: a, to: c, valid_from: nil, attrs: { classification: 1 })
    expect(eager.related.map(&:ref)).to eq([b]) # materialized cache
    expect(eager.reload.related.map(&:ref)).to eq([b, c].sort_by(&:id))
    expect(node_model.in(any).find(a).related.count).to eq(2)
  end

  it "rejects unspecified preload mode before owner SQL even when no owners exist" do
    unspecified = graph.for(viewer: Viewer.new(2))
    expect { node_model.in(unspecified).with_associations(:related).to_a }.to raise_error(Pglpg::TemporalModeRequired)
    expect { edge_model.in(unspecified).count }.to raise_error(Pglpg::TemporalModeRequired)
  end
end
