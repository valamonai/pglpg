# frozen_string_literal: true

RSpec.describe "storage DDL atomicity" do
  def schema(scoped: false, **options)
    Pglpg::Graph.define(:atomic_ddl, **options) do
      node :P do
        property :uid, :string, required: true
        property :namespace, :string, required: scoped
        key(:uid, scope: scoped ? :namespace : nil)
      end
    end
  end

  def insert(c, graph, properties)
    c.execute("INSERT INTO #{c.quote_table_name(graph.nodes_table)} (key_label, labels, properties) VALUES ('P', ARRAY['P'], #{c.quote(properties.to_json)}::jsonb)")
  end

  def properties(c, graph)
    c.select_values("SELECT properties::text FROM #{c.quote_table_name(graph.nodes_table)} ORDER BY id").map { JSON.parse(_1) }
  end

  def indexes(c, graph) = c.indexes(graph.nodes_table).map(&:name).sort

  def reject_duplicate(c, graph)
    expect do
      c.transaction(requires_new: true) { insert(c, graph, { uid: "original", namespace: "other" }) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # Deliberate plan injection: the final DDL fails in PostgreSQL after the
  # tables, traversal indexes and legal initial constraints have been created.
  def fail_initial_sync(storage)
    allow(storage).to receive(:constraints).and_wrap_original do |original, c|
      original.call(c).merge("atomic_invalid" => {
        kind: :check, table: storage.nodes_table,
        sql: "ALTER TABLE #{c.quote_table_name(storage.nodes_table)} ADD CONSTRAINT atomic_invalid CHECK (nonexistent_column > 0)"
      })
    end
  end

  def expect_no_storage(c, graph)
    [graph.nodes_table, graph.edges_table].each do |table|
      expect(c.select_value("SELECT to_regclass(#{c.quote(table)})::text")).to be_nil
      expect(c.select_values("SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename = #{c.quote(table)}")).to be_empty
    end
  end

  it "restores dropped constraints after failure without an outer transaction", :committed do
    c = ActiveRecord::Base.connection
    expect(c.transaction_open?).to be(false)
    old = schema
    old.storage.create!(c)
    insert(c, old, { uid: "original" })
    before = indexes(c, old)
    expect { schema(scoped: true).storage.sync_constraints!(c) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(c.transaction_open?).to be(false)
    expect(indexes(c, old)).to eq(before)
    reject_duplicate(c, old)
  ensure
    old&.storage&.drop!(c)
  end

  it "isolates failed DDL while caller backfill and later writes can commit", :committed do
    c = ActiveRecord::Base.connection
    expect(c.transaction_open?).to be(false)
    old = schema
    old.storage.create!(c)
    insert(c, old, { uid: "original" })
    c.transaction do
      # A real but incomplete backfill: original still has no namespace.
      insert(c, old, { uid: "backfilled" })
      c.execute("UPDATE atomic_ddl_nodes SET properties = properties || '{\"namespace\":\"team\"}'::jsonb WHERE properties->>'uid' = 'backfilled'")
      expect { schema(scoped: true).storage.sync_constraints!(c) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(c.select_value("SELECT 1")).to eq(1)
      reject_duplicate(c, old)
      insert(c, old, { uid: "after" })
    end
    expect(c.transaction_open?).to be(false)
    rows = properties(c, old)
    expect(rows.map { _1["uid"] }).to eq(%w[original backfilled after])
    expect(rows[1]["namespace"]).to eq("team")
  ensure
    old&.storage&.drop!(c)
  end

  it "lets an outer rollback undo the backfill after a rescued sync failure" do
    c = ActiveRecord::Base.connection
    old = schema
    old.storage.create!(c)
    insert(c, old, { uid: "original" })
    c.transaction(requires_new: true) do
      insert(c, old, { uid: "backfilled" })
      c.execute("UPDATE atomic_ddl_nodes SET properties = properties || '{\"namespace\":\"team\"}'::jsonb WHERE properties->>'uid' = 'backfilled'")
      expect { schema(scoped: true).storage.sync_constraints!(c) }.to raise_error(ActiveRecord::StatementInvalid)
      raise ActiveRecord::Rollback
    end
    expect(properties(c, old)).to eq([{ "uid" => "original" }])
    reject_duplicate(c, old)
  end

  it "keeps successful sync and backfill pending until the outer commit" do
    c = ActiveRecord::Base.connection
    old = schema
    old.storage.create!(c)
    insert(c, old, { uid: "original" })
    before = indexes(c, old)
    upgraded = schema(scoped: true)
    c.transaction(requires_new: true) do
      c.execute("UPDATE atomic_ddl_nodes SET properties = properties || '{\"namespace\":\"team\"}'::jsonb")
      expect(upgraded.storage.sync_constraints!(c)).to be_nil
      expect { upgraded.storage.sync_constraints!(c) }.not_to(change { indexes(c, old) })
      insert(c, old, { uid: "original", namespace: "other" })
      raise ActiveRecord::Rollback
    end
    expect(indexes(c, old)).to eq(before)
    expect(properties(c, old)).to eq([{ "uid" => "original" }])
    reject_duplicate(c, old)
  end

  it "rolls back all create DDL on an injected initial-sync failure without an outer transaction", :committed do
    c = ActiveRecord::Base.connection
    expect(c.transaction_open?).to be(false)
    graph = schema
    fail_initial_sync(graph.storage)
    expect { graph.storage.create!(c) }.to raise_error(ActiveRecord::StatementInvalid, /nonexistent_column/)
    expect(c.transaction_open?).to be(false)
    expect_no_storage(c, graph)
  ensure
    graph&.storage&.drop!(c)
  end

  it "preserves unrelated caller writes after nested create failure" do
    c = ActiveRecord::Base.connection
    c.execute("CREATE TEMP TABLE atomic_caller (value integer)")
    c.execute("INSERT INTO atomic_caller VALUES (1)")
    graph = schema
    fail_initial_sync(graph.storage)
    expect { graph.storage.create!(c) }.to raise_error(ActiveRecord::StatementInvalid, /nonexistent_column/)
    expect_no_storage(c, graph)
    c.execute("INSERT INTO atomic_caller VALUES (2)")
    expect(c.select_values("SELECT value FROM atomic_caller ORDER BY value")).to eq([1, 2])
  end

  it "rolls successful create back with its caller" do
    c = ActiveRecord::Base.connection
    graph = schema
    c.transaction(requires_new: true) do
      expect(graph.storage.create!(c)).to be_nil
      expect(c.select_value("SELECT to_regclass('atomic_ddl_nodes')::text")).not_to be_nil
      raise ActiveRecord::Rollback
    end
    expect_no_storage(c, graph)
  end

  it "uses only the explicit second connection for create and sync", :committed do
    c = ActiveRecord::Base.connection
    expect(c.transaction_open?).to be(false)
    unavailable = Class.new do
      def self.lease_connection = raise("graph default connection must not be used")
    end
    graph = schema(connection_class: unavailable)
    ActiveRecord::Base.connection_pool.with_connection do |first|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |second|
          expect(second).not_to equal(first)
          expect(second.transaction_open?).to be(false)
          expect(graph.storage.create!(second)).to be_nil
          expect(graph.storage.sync_constraints!(second)).to be_nil
          graph.storage.drop!(second)
        end
      end.value
    end
  ensure
    c&.execute("DROP TABLE IF EXISTS atomic_ddl_edges, atomic_ddl_nodes")
  end
end
