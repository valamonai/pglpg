# frozen_string_literal: true

RSpec.describe "scoped keys" do
  def define_graph(name = :scoped_spec, **options)
    Pglpg::Graph.define(name, **options) do
      column :classification, :integer, null: false
      node :Agent, abstract: true do
        property :namespace, :string, required: true
        property :uid, :string, required: true
        property :name, :string
        key :uid, scope: :namespace
      end
      node :Person, extends: :Agent
      node :Employee, extends: :Person
      node :Other do
        property :namespace, :string, required: true
        property :uid, :string, required: true
        key :uid, scope: :namespace
      end
    end
  end

  let(:graph) { define_graph }
  let(:context) { graph.for(viewer: Viewer.new(2)) }
  let(:props) { { namespace: "team", uid: "P-1" } }

  before { graph.storage.create! }

  def insert(type = :Person, values = props, level = 1)
    context.insert_node(type, properties: values, attrs: { classification: level })
  end

  it "fails closed before SQL and passes immutable graph/domain/scope identity without uid" do
    statements = []
    ActiveSupport::Notifications.subscribed(->(*args) { statements << args.last[:sql] }, "sql.active_record") do
      expect { insert }.to raise_error(Pglpg::WriteRejected)
    end
    expect(statements).to be_empty
    seen = []
    Pglpg.configuration.key_scope_allowed = ->(request) { seen << request; true }
    ref = insert(:Employee)
    request = seen.first
    expect(request.context).to equal(context)
    expect(request.domain).to eq(:Agent)
    expect(request.scope).to eq(namespace: "team")
    expect(request).to be_frozen
    expect(request.scope).to be_frozen
    expect(request.scope[:namespace]).to be_frozen
    expect(context.find_node(:Person, uid: "P-1", namespace: "team").ref).to eq(ref)
    expect(seen.size).to eq(1)
  end

  it "enforces inherited pair uniqueness while allowing reuse across scopes and domains" do
    Pglpg.configuration.key_scope_allowed = ->(_) { true }
    insert
    expect { insert(:Employee) }.to raise_error(Pglpg::WriteRejected)
    expect(insert(:Employee, props.merge(namespace: "other"))).to be_a(Pglpg::Ref)
    expect(insert(:Other)).to be_a(Pglpg::Ref)
    expect { context.find_node(:Person, uid: "P-1") }.to raise_error(ArgumentError)
    expect(context.match.node(:p, :Person, uid: "P-1").count).to eq(2)
  end

  it "documents the authorized occupancy oracle without revealing a hidden row" do
    Pglpg.configuration.trusted_writer_allowed = ->(_) { true }
    high = graph.for(viewer: Viewer.new(4)).trusted_writer
    high.insert_node(:Person, properties: props, attrs: { classification: 4 })
    Pglpg.configuration.key_scope_allowed = ->(_) { true }
    expect { insert }.to raise_error(Pglpg::WriteRejected) { |error| expect(error.cause).to be_nil }
    expect(context.find_node(:Person, **props)).to be_nil
    expect(insert(:Person, props.merge(uid: "free"))).to be_a(Pglpg::Ref)
  end

  it "does not grant on truthy values or swallow policy exceptions" do
    [nil, false, 1, "yes"].each do |value|
      Pglpg.configuration.key_scope_allowed = ->(_) { value }
      expect { insert }.to raise_error(Pglpg::WriteRejected)
    end
    Pglpg.configuration.key_scope_allowed = ->(_) { raise "policy failed" }
    expect { insert }.to raise_error(RuntimeError, "policy failed")
  end

  it "generates keys without a grant, requires scope, and preserves model key rules" do
    ref = insert(:Person, { namespace: "team" })
    expect(context.find(ref).properties[:uid]).to be_a(String)
    expect { insert(:Person, {}) }.to raise_error(Pglpg::ValidationError)
    expect { insert(:Person, props.merge(namespace: nil)) }.to raise_error(Pglpg::ValidationError)
    g = graph
    model = Class.new(Pglpg::Model::Node) { graph g, type: :Person }
    record = model.in(context).create!(namespace: "team", classification: 1)
    record.reload
    record.namespace = "other"
    expect(record.save).to be(false)
    expect(model.in(context).new(**props, classification: 1).valid?).to be(false)
  end

  it "keeps both parts immutable and isolates trusted upserts by scope" do
    Pglpg.configuration.trusted_writer_allowed = ->(_) { true }
    writer = context.trusted_writer
    a = writer.upsert_node(:Person, key: props, attrs: { classification: 1 })
    expect(writer.upsert_node(:Person, key: props.to_a.reverse.to_h, properties: { name: "new" }, attrs: { classification: 1 })).to eq(a)
    b = writer.upsert_node(:Person, key: props.merge(namespace: "other"), attrs: { classification: 1 })
    expect(b).not_to eq(a)
    %i[namespace uid].each do |part|
      expect { writer.update_node(a, properties: { part => "changed" }) }.to raise_error(ArgumentError)
      expect { writer.upsert_node(:Person, key: props, properties: { part => "changed" }) }.to raise_error(ArgumentError)
    end
  end

  it "allows a per-graph denial to override the global grant" do
    Pglpg.configuration.key_scope_allowed = ->(_) { true }
    denied = define_graph(:scoped_denied, key_scope_allowed: false)
    denied.storage.create!
    expect { denied.for(viewer: Viewer.new(2)).insert_node(:Person, properties: props, attrs: { classification: 1 }) }.to raise_error(Pglpg::WriteRejected)
  end

  it "validates the scope declaration" do
    [[:missing, :string, true], [:namespace, :integer, true], [:namespace, :string, false], [:uid, :string, true]].each do |scope, type, required|
      expect do
        Pglpg::Graph.define(:bad_scope) do
          node :P do
            property :uid, :string, required: true
            property :namespace, type, required: required
            key :uid, scope: scope
          end
        end
      end.to raise_error(Pglpg::SchemaError)
    end
  end

  it "enforces mandatory scope and pair uniqueness on direct SQL" do
    connection = graph.connection
    sql = ->(values) do
      connection.execute("INSERT INTO scoped_spec_nodes (key_label, labels, properties, classification) VALUES ('Person', ARRAY['Agent','Person'], #{connection.quote(values.to_json)}::jsonb, 1)")
    end
    [{ uid: "X" }, { uid: "X", namespace: nil }, { uid: "X", namespace: 1 }].each do |values|
      expect { connection.transaction(requires_new: true) { sql.call(values) } }.to raise_error(ActiveRecord::StatementInvalid)
    end
    sql.call(props)
    expect { connection.transaction(requires_new: true) { sql.call(props) } }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { sql.call(props.merge(namespace: "other")) }.not_to raise_error
  end

  it "preserves visible reads when hidden data in another scope is added" do
    Pglpg.configuration.key_scope_allowed = ->(_) { true }
    ref = insert
    before = context.match.node(:p, :Person, uid: "P-1").to_a
    Pglpg.configuration.trusted_writer_allowed = ->(_) { true }
    graph.for(viewer: Viewer.new(4)).trusted_writer.insert_node(:Employee, properties: props.merge(namespace: "hidden"), attrs: { classification: 4 })
    after = context.match.node(:p, :Person, uid: "P-1").to_a
    expect(after.map { _1[:p].ref }).to eq(before.map { _1[:p].ref })
    expect(context.find_node(:Person, **props).ref).to eq(ref)
  end

  it "arbitrates concurrent chosen inserts with one winner", :committed do
    Pglpg.configuration.key_scope_allowed = ->(_) { true }
    barrier = Queue.new
    workers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          insert
        rescue Pglpg::WriteRejected
          :rejected
        end
      end
    end
    2.times { barrier << true }
    results = workers.map(&:value)
    expect(results.count { _1.is_a?(Pglpg::Ref) }).to eq(1)
    expect(results.count(:rejected)).to eq(1)
    expect(context.match.node(:p, :Person).count).to eq(1)
  ensure
    graph.storage.drop!
  end


  it "rolls back a failed constraint transition and supports a backfilled upgrade" do
    old = Pglpg::Graph.define(:scope_upgrade) do
      column :classification, :integer, default: 1
      node :P do
        property :uid, :string, required: true
        property :namespace, :string
        key :uid
      end
    end
    old.storage.create!
    viewer = old.for(viewer: Viewer.new(2))
    viewer.insert_node(:P)
    upgraded = Pglpg::Graph.define(:scope_upgrade) do
      column :classification, :integer, default: 1
      node :P do
        property :uid, :string, required: true
        property :namespace, :string, required: true
        key :uid, scope: :namespace
      end
    end
    connection = old.connection
    old_indexes = connection.indexes(old.nodes_table).map(&:name).sort
    expect do
      connection.transaction(requires_new: true) { upgraded.storage.sync_constraints! }
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect(connection.indexes(old.nodes_table).map(&:name).sort).to eq(old_indexes)
    connection.transaction(requires_new: true) do
      connection.execute("UPDATE scope_upgrade_nodes SET properties = properties || '{\"namespace\":\"team\"}'::jsonb")
      upgraded.storage.sync_constraints!
    end
    expect(upgraded.for(viewer: Viewer.new(2)).find_node(:P, namespace: "team", uid: viewer.match.node(:p, :P).first[:p].properties[:uid])).not_to be_nil
  end


  it "isolates grants by graph, declaring domain and scope" do
    Pglpg.configuration.key_scope_allowed = ->(request) do
      request.context.graph.equal?(graph) && request.domain == :Agent && request.scope == { namespace: "team" }
    end
    expect(insert(:Employee)).to be_a(Pglpg::Ref)
    expect { insert(:Other) }.to raise_error(Pglpg::WriteRejected)
    expect { insert(:Person, props.merge(namespace: "denied")) }.to raise_error(Pglpg::WriteRejected)
    other = define_graph(:scoped_other)
    other.storage.create!
    expect { other.for(viewer: Viewer.new(2)).insert_node(:Person, properties: props, attrs: { classification: 1 }) }.to raise_error(Pglpg::WriteRejected)
  end

  it "validates and authorizes the write before acquiring occupancy permission" do
    calls = []
    Pglpg.configuration.key_scope_allowed = ->(request) { calls << request; true }
    expect { insert(:Person, props.merge(namespace: 1)) }.to raise_error(Pglpg::ValidationError)
    Pglpg.configuration.write_policy = Class.new do
      def self.authorize?(_) = false
    end
    expect { insert }.to raise_error(Pglpg::WriteRejected)
    expect(calls).to be_empty
  end

end
