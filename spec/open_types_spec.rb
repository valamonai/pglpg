# frozen_string_literal: true

RSpec.describe "open properties (ADR-0015)" do
  def define_graph(open: true, promoted: false, **options)
    Pglpg::Graph.define(:open_spec, **options) do
      column :classification, :integer, null: false
      node :Agent, abstract: true, open: open do
        property :uid, :string, required: true
        property :name, :string
        property :note, :string, required: true if promoted
        key :uid
      end
      node :Person, extends: :Agent
      node :Employee, extends: :Person do
        property :salary, :integer
      end
      node :Closed do
        property :name, :string, required: true
      end
      edge :KNOWS, from: :Agent, to: :Agent, open: open
      edge :RELATED, from: :Agent, to: :Agent, open: open, symmetric: true, temporal: true, unique: [:role] do
        property :role, :string, required: true
        property :uid, :string, required: true
        key :uid
      end
      edge :CLOSED, from: :Agent, to: :Agent
      edge :PAIR, from: :Agent, to: :Agent, unique: :pair, open: open
    end
  end

  let(:graph) { define_graph }
  let(:context) { graph.for(viewer: Viewer.new(4), as_of: :any) }
  let(:writer) { context.trusted_writer }
  let(:attrs) { { classification: 1 } }
  let(:a) { writer.insert_node(:Person, properties: { uid: "a", name: "Ann" }, attrs:) }
  let(:b) { writer.insert_node(:Person, properties: { uid: "b", name: "Bob" }, attrs:) }

  before { graph.storage.create! }

  it "keeps existing types closed by default and validates the open flag" do
    expect(Kg.type.node_type!(:Person).open?).to be(false)
    expect(Kg.type.edge_type!(:KNOWS).open?).to be(false)
    expect { context.insert_node(:Closed, properties: { name: "x", extra: 1 }, attrs:) }.to raise_error(Pglpg::ValidationError, /no property/)
    expect { context.insert_edge(:CLOSED, from: a, to: b, properties: { extra: 1 }, attrs:) }.to raise_error(Pglpg::ValidationError)
    closed = graph.type.node_type!(:Closed)
    expect(closed.encode_properties({ "name" => "first", name: "last" })).to eq("name" => "last")
    expect { graph.type.node_type!(:Person).encode_properties({ "name" => "first", name: "last" }) }.to raise_error(Pglpg::ValidationError, /duplicate/)
    [nil, 0, "true", :yes].each do |flag|
      expect { Pglpg::Graph.define(:bad) { node :N, open: flag } }.to raise_error(Pglpg::SchemaError, /open/)
      expect { Pglpg::Graph.define(:bad) { node :N; edge :E, from: :N, to: :N, open: flag } }.to raise_error(Pglpg::SchemaError, /open/)
    end
  end

  it "inherits openness from any parent and cannot close an open ancestor" do
    g = Pglpg::Graph.define(:inherit_open) do
      node(:Open, open: true) { property :name, :string, required: true }
      node(:Closed) { property :rank, :integer }
      node :Child, extends: %i[Closed Open], open: false
      node :Grandchild, extends: :Child
      node :Explicit, extends: :Closed, open: true
      node :StillClosed, extends: :Closed
    end
    %i[Open Child Grandchild Explicit].each { expect(g.type.node_type!(_1).open?).to be(true) }
    expect(g.type.node_type!(:StillClosed).open?).to be(false)
    child = g.type.node_type!(:Child)
    expect(child.encode_properties({ name: "Ann", extra: 1 })).to include("extra" => 1)
    expect { child.encode_properties({ extra: 1 }) }.to raise_error(Pglpg::ValidationError, /required/)
    expect do
      Pglpg::Graph.define(:bad) do
        node(:A, open: true) { property :x, :string }
        node(:B) { property :x, :integer }
        node :C, extends: %i[A B]
      end
    end.to raise_error(Pglpg::SchemaError, /conflicting/)
  end

  it "round-trips the scalar/list value subset and removes extras with nil" do
    extras = { text: "hello", integer: 10, float: 1.25, flag: false, empty: [], strings: ["a", "b"], integers: [1, 2], floats: [1.0, 2.5], booleans: [true, false] }
    ref = context.insert_node(:Person, properties: { name: "Ann", **extras }, attrs:)
    expect(context.find(ref).properties.slice(*extras.keys)).to eq(extras)
    context.update_node(ref, properties: { text: nil, strings: ["new"], missing: nil })
    stored = context.find(ref)
    expect(stored.properties).not_to have_key(:text)
    expect(stored.properties).not_to have_key(:missing)
    expect(stored[:strings]).to eq(["new"])
    expect(stored[:flag]).to be(false)
    expect(stored[:strings]).to be_frozen
    expect(stored[:strings].first).to be_frozen
    expect { stored[:strings] << "bad" }.to raise_error(FrozenError)
  end

  it "rejects unsupported values without accidental JSON serialization or SQL" do
    source, target = a, b
    custom = Object.new
    def custom.to_json(*) = raise("must not serialize this object")
    invalid = [custom, :symbol, BigDecimal("1.0"), Date.new(2020, 1, 1), Time.now, Float::NAN, Float::INFINITY,
               {}, [nil], [[1]], [{ a: 1 }], [1, 1.0], ["x", 1], "nul\0byte", "\xff".b.force_encoding(Encoding::UTF_8)]
    invalid.each do |value|
      statements = []
      ActiveSupport::Notifications.subscribed(->(*args) { statements << args.last[:sql] }, "sql.active_record") do
        expect { context.insert_node(:Person, properties: { extra: value }, attrs:) }.to raise_error(Pglpg::ValidationError)
        expect { context.insert_edge(:KNOWS, from: source, to: target, properties: { extra: value }, attrs:) }.to raise_error(Pglpg::ValidationError)
      end
      expect(statements).to be_empty
    end
  end

  it "deeply freezes historical map keys independently of JSON deserialization" do
    outer_key, inner_key = +"outer", +"inner"
    inner = {}.compare_by_identity
    inner[inner_key] = ["value"]
    legacy = {}.compare_by_identity
    legacy[outer_key] = inner
    expect(outer_key).not_to be_frozen
    expect(inner_key).not_to be_frozen
    decoded = graph.type.node_type!(:Person).decode_properties({ "payload" => legacy })
    expect(decoded[:payload]).to be_frozen
    expect(outer_key).to be_frozen
    expect(inner_key).to be_frozen
    expect(inner).to be_frozen
    expect(inner[inner_key]).to be_frozen
    expect(inner[inner_key].first).to be_frozen
    json = graph.connection.quote({ payload: { outer: { inner: ["value"] } } }.to_json)
    graph.connection.execute("UPDATE open_spec_nodes SET properties = properties || #{json}::jsonb WHERE id = #{a.id}")
    from_sql = context.find(a)[:payload]
    expect(from_sql.keys.first).to be_frozen
    expect(from_sql["outer"].keys.first).to be_frozen
    expect(from_sql["outer"]["inner"].first).to be_frozen
  end

  it "rejects invalid update extras before data statements while retaining visible-target preflights" do
    context.update_node(a, properties: { note: "kept" })
    edge = context.insert_edge(:KNOWS, from: a, to: b, properties: { note: "kept" }, attrs:)
    writes = []
    ActiveSupport::Notifications.subscribed(->(*args) { writes << args.last[:sql] if args.last[:sql].match?(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i) }, "sql.active_record") do
      [{ note: {} }, { classification: nil }, { "note" => "first", note: "last" }].each do |properties|
        expect { context.update_node(a, properties:) }.to raise_error(Pglpg::ValidationError)
        expect { context.update_edge(edge, properties:) }.to raise_error(Pglpg::ValidationError)
      end
    end
    expect(writes).to be_empty
    expect(context.find(a)[:note]).to eq("kept")
    expect(context.find(edge)[:note]).to eq("kept")
  end

  it "merges and removes extras through non-key pair upserts" do
    ref = writer.upsert_edge(:PAIR, from: a, to: b, properties: { note: "first", tags: [1, 2] }, attrs:)
    expect(writer.upsert_edge(:PAIR, from: a, to: b, properties: { note: nil, flag: false }, attrs:)).to eq(ref)
    expect(context.find(ref).properties).to eq(tags: [1, 2], flag: false)
    writes = []
    ActiveSupport::Notifications.subscribed(->(*args) { writes << args.last[:sql] if args.last[:sql].match?(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i) }, "sql.active_record") do
      expect { writer.upsert_edge(:PAIR, from: a, to: b, properties: { tags: [[1]] }, attrs:) }.to raise_error(Pglpg::ValidationError)
    end
    expect(writes).to be_empty
    expect(context.find(ref).properties).to eq(tags: [1, 2], flag: false)
  end

  it "refuses invalid names, duplicate aliases, row metadata, app columns and validity names" do
    invalid = [{ "bad-name" => 1 }, { 1 => "bad" }, { "extra" => 1, extra: 2 }, { "name" => "a", name: "b" }]
    (Pglpg::Schema::Column::RESERVED + Pglpg::Temporal::NAMES + [:classification]).each { invalid << { _1 => nil } }
    invalid.each do |properties|
      expect { context.insert_node(:Person, properties:, attrs:) }.to raise_error(Pglpg::ValidationError)
      expect { writer.upsert_node(:Person, key: { uid: "x" }, properties:, attrs:) }.to raise_error(Pglpg::ValidationError)
    end
    expect { context.insert_node(:Person, properties: { classification: 1 }, attrs: {}) }.to raise_error(Pglpg::ValidationError)
    expect { context.insert_edge(:KNOWS, from: a, to: b, properties: { source_id: a.id }, attrs:) }.to raise_error(Pglpg::ValidationError)
    # Even a timeless graph reserves validity names in undeclared extras.
    g = Pglpg::Graph.define(:timeless_open) { node :N, open: true }
    expect { g.type.node_type!(:N).encode_properties({ valid_from: nil }) }.to raise_error(Pglpg::ValidationError)
  end

  it "retains declared strict types and inherited key rules on every write" do
    expect { context.insert_node(:Employee, properties: { salary: "100", extra: 1 }, attrs:) }.to raise_error(Pglpg::ValidationError)
    expect { context.insert_node(:Person, properties: { uid: "chosen", extra: 1 }, attrs:) }.to raise_error(ArgumentError)
    expect { writer.upsert_node(:Person, key: { uid: "a" }, properties: { uid: "other" }, attrs:) }.to raise_error(ArgumentError)
    expect { writer.update_node(a, properties: { uid: "other", extra: 1 }) }.to raise_error(ArgumentError)
    expect { writer.insert_edge(:RELATED, from: a, to: b, properties: { uid: "e", extra: 1 }, attrs:, valid_from: nil) }.to raise_error(Pglpg::ValidationError, /role/)
    expect { writer.insert_edge(:RELATED, from: a, to: b, properties: { uid: "e", role: "x", valid_to: nil }, attrs:, valid_from: nil) }.to raise_error(Pglpg::ValidationError, /reserved/)
  end

  it "merges extras on trusted upsert and preserves existing write policy visibility" do
    ref = writer.upsert_node(:Person, key: { uid: "x" }, properties: { note: "first", tags: [1, 2] }, attrs:)
    expect(writer.upsert_node(:Person, key: { uid: "x" }, properties: { note: nil, added: true }, attrs:)).to eq(ref)
    expect(context.find(ref).properties).to include(tags: [1, 2], added: true)
    expect(context.find(ref).properties).not_to have_key(:note)
    writer.insert_node(:Person, properties: { uid: "hidden", secret: "hidden" }, attrs: { classification: 4 })
    Pglpg.configuration.trusted_writer_allowed = ->(_) { true }
    low = graph.for(viewer: Viewer.new(1), as_of: :any)
    expect { low.trusted_writer.upsert_node(:Person, key: { uid: "hidden" }, properties: { note: "probe" }, attrs:) }.to raise_error(Pglpg::WriteRejected) { expect(_1.cause).to be_nil }
    expect(low.find_node(:Person, uid: "hidden")).to be_nil
  end

  it "lets ordinary policy inspect extras and preserves authorization order" do
    seen = []
    policy = Module.new do
      define_singleton_method(:authorize?) { |request| seen << request; request.properties[:source] == "allowed" }
    end
    g = define_graph(write_policy: policy)
    ctx = g.for(viewer: Viewer.new(4), as_of: :any)
    expect { ctx.insert_node(:Person, properties: { source: "denied" }, attrs:) }.to raise_error(Pglpg::WriteRejected)
    expect(ctx.insert_node(:Person, properties: { source: "allowed" }, attrs:)).to be_a(Pglpg::Ref)
    expect(seen.last.properties[:source]).to eq("allowed")
    expect { ctx.insert_node(:Person, properties: { source: {} }, attrs:) }.to raise_error(Pglpg::ValidationError)
    expect(seen.size).to eq(2)
  end

  it "supports extras on ordinary edges and on symmetric temporal keyed upserts" do
    edge = context.insert_edge(:KNOWS, from: a, to: b, properties: { note: "one", tags: ["a"] }, attrs:)
    context.update_edge(edge, properties: { note: nil, other: false })
    expect(context.find(edge).properties).to eq(tags: ["a"], other: false)
    keyed = writer.upsert_edge(:RELATED, from: b, to: a, key: { uid: "related" }, properties: { role: "x", confidence: 0.5 }, attrs:, valid_from: Date.new(2020, 1, 1), valid_to: Date.new(2021, 1, 1))
    expect(writer.upsert_edge(:RELATED, from: a, to: b, key: { uid: "related" }, properties: { role: "x", evidence: [1, 2] }, attrs:, valid_from: Date.new(2020, 1, 1))).to eq(keyed)
    at = graph.for(viewer: Viewer.new(4), as_of: Date.new(2020, 6, 1))
    expect(at.find_edge(:RELATED, uid: "related").properties).to include(confidence: 0.5, evidence: [1, 2])
    expect(graph.for(viewer: Viewer.new(4), as_of: Date.new(2022, 1, 1)).find_edge(:RELATED, uid: "related")).to be_nil
    expect { writer.update_edge(keyed, properties: { role: "other", evidence: [] }) }.to raise_error(ArgumentError)
  end

  it "requires declarations for filtering, ordering and model pluck before SQL" do
    g = graph
    model = Class.new(Pglpg::Model::Node) { graph g, type: :Person }
    statements = []
    ActiveSupport::Notifications.subscribed(->(*args) { statements << args.last[:sql] }, "sql.active_record") do
      expect { context.match.node(:n, :Person, extra: 1) }.to raise_error(ArgumentError, /no property/)
      expect { context.match.node(:n, :Person).order(n: :extra) }.to raise_error(ArgumentError, /no property/)
      expect { context.match.node(:n, :Person).out(:KNOWS, :p, edge: :e).where(e: { extra: 1 }) }.to raise_error(ArgumentError, /no property/)
      expect { model.in(context).pluck(:extra) }.to raise_error(ArgumentError)
    end
    expect(statements).to be_empty
  end

  it "keeps model extras read-only and preserves them across declared saves and reload" do
    g = graph
    parent = Class.new(Pglpg::Model::Node) { graph g, type: :Person }
    edge_model = Class.new(Pglpg::Model::Edge) { graph g, type: :KNOWS }
    ref = writer.insert_node(:Employee, properties: { uid: "emp", salary: 10, name: "Ann", tags: ["extra"] }, attrs:)
    record = parent.in(context).find(ref)
    expect(record.extra_properties).to eq(salary: 10, tags: ["extra"])
    expect(record.extra_properties).to be_frozen
    expect(record.extra_properties[:tags]).to be_frozen
    expect { record.assign_attributes(tags: ["other"]) }.to raise_error(ActiveModel::UnknownAttributeError)
    expect { parent.in(context).new(extra: 1, classification: 1) }.to raise_error(ActiveModel::UnknownAttributeError)
    record.name = "Changed"
    record.save!
    expect(context.find(ref).properties).to include(tags: ["extra"], salary: 10, name: "Changed")
    context.update_node(ref, properties: { tags: ["updated"] })
    expect(record.extra_properties[:tags]).to eq(["extra"])
    expect(record.reload.extra_properties[:tags]).to eq(["updated"])
    edge = context.insert_edge(:KNOWS, from: a, to: b, properties: { evidence: [1, 2] }, attrs:)
    bound = edge_model.in(context).find(edge)
    bound.classification = 2
    bound.save!
    expect(bound.reload.extra_properties).to eq(evidence: [1, 2])
  end

  it "needs no openness DDL and preserves historical extras when closing a type" do
    closed = define_graph(open: false)
    expect(closed.storage.constraints).to eq(graph.storage.constraints)
    ref = writer.insert_node(:Person, properties: { uid: "legacy", note: "kept" }, attrs:)
    old_context = closed.for(viewer: Viewer.new(4), as_of: :any)
    expect(old_context.find(ref)[:note]).to eq("kept")
    old_context.update_node(ref, properties: { name: "known" })
    expect(old_context.find(ref)[:note]).to eq("kept")
    expect { old_context.update_node(ref, properties: { note: nil }) }.to raise_error(Pglpg::ValidationError)
    promoted = define_graph(open: false, promoted: true)
    bad = writer.insert_node(:Person, properties: { uid: "needs-backfill", note: 8 }, attrs:)
    catalog = -> { graph.connection.select_values("SELECT conname FROM pg_constraint WHERE conrelid = 'open_spec_nodes'::regclass ORDER BY conname") }
    before = catalog.call
    expect { promoted.storage.sync_constraints! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(catalog.call).to eq(before)
    graph.connection.transaction(requires_new: true) do
      graph.connection.execute("UPDATE open_spec_nodes SET properties = properties || '{\"note\":\"backfilled\"}'::jsonb WHERE id = #{bad.id}")
      promoted.storage.sync_constraints!
    end
    expect(promoted.for(viewer: Viewer.new(4), as_of: :any).find(ref)[:note]).to eq("kept")
    expect(promoted.for(viewer: Viewer.new(4), as_of: :any).find(bad)[:note]).to eq("backfilled")
  end
end
