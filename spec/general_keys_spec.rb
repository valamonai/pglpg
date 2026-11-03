# frozen_string_literal: true

RSpec.describe "general keys (ADR-0014)" do
  def define_graph(**options)
    Pglpg::Graph.define(:general_keys, **options) do
      column :classification, :integer, null: false
      node :Record, abstract: true do
        property :catalog, :string, required: true
        property :number, :integer, required: true
        property :active, :boolean, required: true
        property :name, :string
        key :catalog, :number, :active
      end
      node :Document, extends: :Record
      node :Report, extends: :Document
      node :Other do
        property :catalog, :string, required: true
        property :number, :integer, required: true
        property :active, :boolean, required: true
        key :catalog, :number, :active
      end
      node :Count do
        property :number, :integer, required: true
        key :number
      end
      edge :CITES, from: :Record, to: :Record do
        property :catalog, :string, required: true
        property :number, :integer, required: true
        property :note, :string
        key :catalog, :number
      end
      edge :ASSIGNED, from: :Record, to: :Record, symmetric: true, temporal: true, unique: [:role] do
        property :role, :enum, values: %w[lead reviewer], required: true
        property :note, :string
      end
      edge :KEYED_PAIR, from: :Record, to: :Record, unique: [:role] do
        property :uid, :string, required: true
        property :role, :string, required: true
        key :uid
      end
      edge :TAGGED, from: :Record, to: :Record do
        property :uid, :string, required: true
        property :note, :string
        key :uid
      end
    end
  end

  let(:graph) { define_graph }
  let(:context) { graph.for(viewer: Viewer.new(4), as_of: :any) }
  let(:writer) { context.trusted_writer }
  let(:key) { { catalog: "library", number: 1, active: false } }
  let(:attrs) { { classification: 1 } }
  let(:a) { writer.insert_node(:Document, properties: key, attrs:) }
  let(:b) { writer.insert_node(:Document, properties: key.merge(number: 2), attrs:) }
  let(:c) { writer.insert_node(:Document, properties: key.merge(number: 3), attrs:) }

  before { graph.storage.create! }

  it "shares a composite key domain across inherited labels but not unrelated types" do
    expect(context.find_node(:Record, **key)).to be_nil
    ref = a
    expect(context.find_node(:Record, **key).ref).to eq(ref)
    expect(context.find_node(:Document, **key.to_a.reverse.to_h).ref).to eq(ref)
    expect { writer.insert_node(:Report, properties: key, attrs:) }.to raise_error(Pglpg::WriteRejected)
    expect(writer.insert_node(:Other, properties: key, attrs:)).not_to eq(ref)
    expect(writer.insert_node(:Document, properties: key.merge(active: true), attrs:)).not_to eq(ref)
    expect(writer.upsert_node(:Document, key:, properties: { name: "updated" }, attrs:)).to eq(ref)
    expect { writer.upsert_node(:Report, key:, attrs:) }.to raise_error(Pglpg::WriteRejected)
    expect(context.find(ref)[:name]).to eq("updated")
  end

  it "rejects interactive general keys independently of input and occupancy before SQL" do
    a
    low = graph.for(viewer: Viewer.new(1))
    Pglpg.configuration.key_scope_allowed = ->(_) { raise "must not grant general keys" }
    [{}, key, key.merge(number: 99)].each do |properties|
      statements = []
      ActiveSupport::Notifications.subscribed(->(*args) { statements << args.last[:sql] }, "sql.active_record") do
        expect { low.insert_node(:Document, properties:, attrs:) }.to raise_error(ArgumentError, /trusted writer/)
      end
      expect(statements).to be_empty
    end
  end

  it "requires complete literal keys, including false, before SQL" do
    a
    [key.except(:active), key.merge(extra: 1), key.merge(number: [1]), key.merge(number: Pglpg.gt(0)), key.merge(active: nil)].each do |bad|
      expect { context.find_node(:Document, **bad) }.to raise_error { |error| expect(error.is_a?(ArgumentError) || error.is_a?(Pglpg::ValidationError)).to be(true) }
    end
    expect(context.find_node(:Document, **key).ref).to eq(a)
    ref = writer.upsert_node(:Count, key: { number: 7 }, attrs:)
    expect(context.find_node(:Count, number: 7).ref).to eq(ref)
  end

  it "refuses every node key component on updates and duplicate key arguments on upsert" do
    key.each_key do |property|
      expect { writer.update_node(a, properties: { property => key[property] }) }.to raise_error(ArgumentError)
      expect { writer.upsert_node(:Document, key:, properties: { property => key[property] }, attrs:) }.to raise_error(ArgumentError)
    end
  end

  it "finds and upserts a global edge key while refusing endpoint changes" do
    edge_key = { catalog: "source", number: 1 }
    edge = writer.upsert_edge(:CITES, from: a, to: b, key: edge_key, properties: { note: "old" }, attrs:)
    expect(writer.upsert_edge(:CITES, from: a, to: b, key: edge_key, properties: { note: "new" }, attrs:)).to eq(edge)
    expect(context.find_edge(:CITES, **edge_key).ref).to eq(edge)
    expect(context.find_edge(:CITES, **edge_key)[:note]).to eq("new")
    expect { writer.upsert_edge(:CITES, from: a, to: c, key: edge_key, attrs:) }.to raise_error(Pglpg::WriteRejected) { expect(_1.cause).to be_nil }
    expect { writer.insert_edge(:CITES, from: b, to: c, properties: edge_key, attrs:) }.to raise_error(Pglpg::WriteRejected)
    expect(context.find(edge).target).to eq(b)
    expect { writer.update_edge(edge, properties: { number: 2 }) }.to raise_error(ArgumentError)
    expect { writer.upsert_edge(:CITES, from: a, to: b, attrs:) }.to raise_error(ArgumentError, /key/)
    expect { writer.upsert_edge(:CITES, from: a, to: b, key: edge_key, properties: edge_key, attrs:) }.to raise_error(ArgumentError)
    expect { context.find_edge(:CITES, catalog: "source") }.to raise_error(ArgumentError)
  end

  it "retains generated edge keys and the model generation rules" do
    low = graph.for(viewer: Viewer.new(1), as_of: :any)
    edge = low.insert_edge(:TAGGED, from: a, to: b, attrs:)
    uid = low.find(edge)[:uid]
    expect(low.find_edge(:TAGGED, uid:).ref).to eq(edge)
    expect { low.insert_edge(:TAGGED, from: a, to: b, properties: { uid: }, attrs:) }.to raise_error(ArgumentError, /generated/)
    expect { low.insert_edge(:CITES, from: a, to: b, attrs:) }.to raise_error(ArgumentError, /trusted/)
    g = graph
    model = Class.new(Pglpg::Model::Edge) { graph g, type: :TAGGED }
    record = model.in(low).create!(source: a, target: b, classification: 1)
    expect(record.key).to be_nil
    expect(record.reload.key).to be_a(String)
    expect(model.in(context).new(source: a, target: b, classification: 1, uid: "chosen").valid?).to be(false)
  end

  it "uses symmetric pair/property tuples across all dates and protects their updates" do
    options = { properties: { role: "lead" }, attrs:, valid_from: Date.new(2020, 1, 1), valid_to: Date.new(2021, 1, 1) }
    edge = writer.upsert_edge(:ASSIGNED, from: a, to: b, **options)
    expect(writer.upsert_edge(:ASSIGNED, from: b, to: a, **options)).to eq(edge)
    expect(writer.insert_edge(:ASSIGNED, from: b, to: a, **options.merge(properties: { role: "reviewer" }))).not_to eq(edge)
    expect { writer.insert_edge(:ASSIGNED, from: a, to: b, **options.merge(valid_from: Date.new(2022, 1, 1), valid_to: nil)) }.to raise_error(Pglpg::WriteRejected)
    expect { context.insert_edge(:ASSIGNED, from: a, to: b, **options) }.to raise_error(ArgumentError, /unique/)
    expect { writer.update_edge(edge, properties: { role: "reviewer" }) }.to raise_error(ArgumentError)
    expect { context.find_edge(:ASSIGNED, role: "lead") }.to raise_error(ArgumentError, /no property key/)
    expect { writer.upsert_edge(:ASSIGNED, from: a, to: b, key: { role: "lead" }, **options) }.to raise_error(ArgumentError)
  end

  it "enforces cumulative key and pair constraints without moving pair properties" do
    edge = writer.upsert_edge(:KEYED_PAIR, from: a, to: b, key: { uid: "one" }, properties: { role: "lead" }, attrs:)
    expect { writer.upsert_edge(:KEYED_PAIR, from: a, to: b, key: { uid: "one" }, properties: { role: "other" }, attrs:) }.to raise_error(Pglpg::WriteRejected)
    expect { writer.upsert_edge(:KEYED_PAIR, from: a, to: b, key: { uid: "two" }, properties: { role: "lead" }, attrs:) }.to raise_error(Pglpg::WriteRejected)
    expect(context.find(edge)[:role]).to eq("lead")
  end

  it "keeps hidden collisions generic and applies visibility to both keyed-edge endpoints" do
    writer.insert_node(:Document, properties: key.merge(number: 8), attrs: { classification: 4 })
    low = graph.for(viewer: Viewer.new(1), as_of: :any)
    # Grant a trusted capability to a low viewer without widening read/write policy.
    Pglpg.configuration.trusted_writer_allowed = ->(_) { true }
    expect { low.trusted_writer.upsert_node(:Document, key: key.merge(number: 8), attrs:) }.to raise_error(Pglpg::WriteRejected) { expect(_1.cause).to be_nil }
    expect(low.find_node(:Document, **key.merge(number: 8))).to be_nil
    edge_key = { catalog: "hidden", number: 1 }
    writer.insert_edge(:CITES, from: a, to: b, properties: edge_key, attrs: { classification: 4 })
    expect(low.find_edge(:CITES, **edge_key)).to be_nil
    expect { low.trusted_writer.upsert_edge(:CITES, from: a, to: b, key: edge_key, attrs:) }.to raise_error(Pglpg::WriteRejected) { expect(_1.cause).to be_nil }
    hidden = writer.insert_node(:Document, properties: key.merge(number: 9), attrs: { classification: 4 })
    writer.insert_edge(:CITES, from: hidden, to: a, properties: edge_key.merge(number: 2), attrs:)
    writer.insert_edge(:CITES, from: a, to: hidden, properties: edge_key.merge(number: 3), attrs:)
    [2, 3].each { expect(low.find_edge(:CITES, **edge_key.merge(number: _1))).to be_nil }
  end

  it "creates composite-key models only through the same-context writer and keeps keys immutable" do
    g = graph
    node_model = Class.new(Pglpg::Model::Node) { graph g, type: :Document }
    edge_model = Class.new(Pglpg::Model::Edge) { graph g, type: :CITES }
    record = node_model.in(context).new(**key, classification: 1)
    expect(record).to be_valid
    expect { record.save! }.to raise_error(ArgumentError, /trusted/)
    expect(record.save!(writer:)).to be(true)
    expect(record.key).to eq(key)
    expect(record.key).to be_frozen
    record.number = 5
    expect(record.save(writer:)).to be(false)
    edge = edge_model.in(context).new(source: record, target: b, catalog: "source", number: 1, classification: 1)
    expect(edge.save!(writer:)).to be(true)
    expect(edge.key).to eq(catalog: "source", number: 1)
    edge.number = 5
    expect(edge.save(writer:)).to be(false)
  end

  def raw_node(properties)
    connection = graph.connection
    connection.transaction(requires_new: true) do
      connection.execute("INSERT INTO general_keys_nodes (key_label, labels, properties, classification) VALUES ('Document', ARRAY['Document','Record'], #{connection.quote(properties.to_json)}::jsonb, 1)")
    end
  end

  it "enforces tuple presence, integer equality and integral values through direct SQL" do
    a
    [key.except(:active), key.merge(active: nil), key.merge(number: "1"), key.merge(number: 1.5), key.merge(number: 1.0)].each do |bad|
      expect { raw_node(bad) }.to raise_error(ActiveRecord::StatementInvalid)
    end
    expect(context.find_node(:Document, **key).ref).to eq(a)
    expect { graph.storage.sync_constraints! }.not_to raise_error
  end

  it "can use the full unique index for composite, numeric and edge key lookups" do
    a
    edge = writer.insert_edge(:CITES, from: a, to: b, properties: { catalog: "source", number: 1 }, attrs:)
    writer.insert_node(:Count, properties: { number: 7 }, attrs:)
    graph.connection.execute("SET LOCAL enable_seqscan = off")
    node_plan = context.match.node(:n, :Document, **key).explain.join("\n")
    expect(node_plan).to include("key_Record_catalog_number", "Index Cond:")
    expect(node_plan.lines.grep(/Index Cond/).join).to include("catalog", "number", "active")
    numeric_plan = context.match.node(:n, :Count, number: 7).explain.join("\n")
    expect(numeric_plan).to include("key_Count_number", "Index Cond:")
    edge_plan = context.match.node(:s).out(:CITES, :t, edge: :e).where(e: { catalog: "source", number: 1 }).explain.join("\n")
    expect(edge_plan).to include("key_CITES_catalog_number", "Index Cond:")
    expect(context.find_edge(:CITES, catalog: "source", number: 1).ref).to eq(edge)
  end

  it "rejects invalid tuple declarations and unsupported equality types" do
    [[], [:x, :x], [:missing]].each do |names|
      expect do
        Pglpg::Graph.define(:bad) { node(:N) { property :x, :string, required: true; key(*names) } }
      end.to raise_error(Pglpg::SchemaError)
    end
    %i[float decimal date datetime list].each do |type|
      expect do
        Pglpg::Graph.define(:bad) { node(:N) { property :x, type, required: true, of: :string; key :x } }
      end.to raise_error(Pglpg::SchemaError)
    end
    expect do
      Pglpg::Graph.define(:bad) { node(:N) { property :x, :string, required: true; property :y, :string, required: true; key :x, :y, generate: ->(_) { "x" } } }
    end.to raise_error(Pglpg::SchemaError)
    expect do
      Pglpg::Graph.define(:bad) { node(:N); edge(:E, from: :N, to: :N, unique: [:x]) { property :x, :string } }
    end.to raise_error(Pglpg::SchemaError)
  end

  it "enforces edge enum membership and tuple presence on direct SQL" do
    source, target = a.id, b.id
    connection = graph.connection
    [{ role: "unknown" }, {}, { role: nil }, { role: 2 }].each do |properties|
      expect do
        connection.transaction(requires_new: true) do
          connection.execute("INSERT INTO general_keys_edges (type, source_id, target_id, properties, classification) VALUES ('ASSIGNED', #{source}, #{target}, #{connection.quote(properties.to_json)}::jsonb, 1)")
        end
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  it "keeps model pair-uniqueness properties immutable" do
    g = graph
    model = Class.new(Pglpg::Model::Edge) { graph g, type: :ASSIGNED }
    record = model.in(context).new(source: a, target: b, role: "lead", valid_from: nil, classification: 1)
    record.save!(writer:)
    record.role = "reviewer"
    expect(record.save(writer:)).to be(false)
    expect(record.errors[:role]).to include("cannot be changed")
  end

  it "guards dated keyed lookup and writes through the schema before occupancy queries" do
    dated = graph.for(viewer: Viewer.new(4), as_of: Date.new(2020, 1, 1))
    # The timeless edge key can be read without a temporal mode.
    edge = writer.insert_edge(:TAGGED, from: a, to: b, attrs:)
    uid = context.find(edge)[:uid]
    expect(graph.for(viewer: Viewer.new(4)).find_edge(:TAGGED, uid:).ref).to eq(edge)
    expect { dated.insert_edge(:TAGGED, from: a, to: b, attrs:) }.to raise_error(Pglpg::ReadOnlyContext)
    temporal = Pglpg::Graph.define(:keyed_time) do
      node :N
      edge(:E, from: :N, to: :N, temporal: true) { property :uid, :string, required: true; key :uid }
    end
    expect { temporal.for(viewer: Viewer.new(4)).find_edge(:E, uid: "x") }.to raise_error(Pglpg::TemporalModeRequired)
  end

  it "restores legacy constraints after a failed tuple migration and accepts an explicit backfill" do
    old = Pglpg::Graph.define(:key_upgrade) do
      node(:N) { property :uid, :string, required: true; key :uid }
    end
    upgraded = Pglpg::Graph.define(:key_upgrade) do
      node(:N) do
        property :uid, :string, required: true
        property :version, :integer, required: true
        key :uid, :version
      end
    end
    old.storage.create!
    connection = graph.connection
    connection.execute("INSERT INTO key_upgrade_nodes (key_label, labels, properties) VALUES ('N', ARRAY['N'], '{\"uid\":\"one\"}')")
    before = connection.indexes(old.nodes_table).map(&:name).sort
    expect { upgraded.storage.sync_constraints! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(connection.indexes(old.nodes_table).map(&:name).sort).to eq(before)
    expect do
      connection.transaction(requires_new: true) do
        connection.execute("INSERT INTO key_upgrade_nodes (key_label, labels, properties) VALUES ('N', ARRAY['N'], '{\"uid\":\"one\"}')")
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
    connection.transaction(requires_new: true) do
      connection.execute("UPDATE key_upgrade_nodes SET properties = properties || '{\"version\":1}'::jsonb")
      upgraded.storage.sync_constraints!
    end
    expect(connection.indexes(old.nodes_table).map(&:name)).not_to include(*before.select { _1.start_with?("pglpg_") })
    connection.execute("INSERT INTO key_upgrade_nodes (key_label, labels, properties) VALUES ('N', ARRAY['N'], '{\"uid\":\"one\",\"version\":2}')")
    expect(connection.select_value("SELECT count(*) FROM key_upgrade_nodes")).to eq(2)
  end

  it "serializes competing composite node and keyed-edge writes with PostgreSQL arbiters", :committed do
    source, target = a, b
    race = lambda do |&work|
      start = Queue.new
      threads = Array.new(6) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            start.pop
            work.call
          end
        end
      end
      6.times { start << true }
      threads.map(&:value)
    end
    refs = race.call { writer.upsert_node(:Document, key: key.merge(number: 50), attrs:) }
    expect(refs.uniq.size).to eq(1)
    edges = race.call { writer.upsert_edge(:CITES, from: source, to: target, key: { catalog: "race", number: 1 }, attrs:) }
    expect(edges.uniq.size).to eq(1)
    outcomes = race.call do
      writer.insert_node(:Document, properties: key.merge(number: 51), attrs:)
    rescue Pglpg::WriteRejected
      :rejected
    end
    expect(outcomes.count(:rejected)).to eq(5)
    expect(outcomes.grep(Pglpg::Ref).size).to eq(1)
  ensure
    graph.storage.drop!
  end
end
