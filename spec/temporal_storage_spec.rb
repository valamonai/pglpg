# frozen_string_literal: true

RSpec.describe "explicit temporal storage transitions" do
  def schema(temporal: [], **options)
    Pglpg::Graph.define(:temporal_migration, **options) do
      column :classification, :integer
      node :P
      edge :T, from: :P, to: :P, temporal: temporal.include?(:T)
      edge :U, from: :P, to: :P, temporal: temporal.include?(:U)
    end
  end

  def seed(g, type = :T)
    c = g.for(viewer: Viewer.new(4))
    a = c.insert_node(:P, attrs: { classification: 1 })
    c.insert_edge(type, from: a, to: a, attrs: { classification: 1 })
  end

  def columns(g) = g.connection.columns(g.edges_table).map(&:name)

  def checks(g)
    g.connection.select_values("SELECT conname FROM pg_constraint WHERE conrelid = 'temporal_migration_edges'::regclass AND contype = 'c' ORDER BY conname")
  end

  it "refuses implicit enablement on populated storage and explicitly acknowledges all-time without invented dates" do
    old = schema
    old.storage.create!
    ref = seed(old)
    g = schema(temporal: [:T])
    expect { g.storage.sync_constraints! }.to raise_error(Pglpg::TemporalMigrationRequired, /enable_temporal/)
    expect(columns(g)).not_to include("valid_from")
    expect(g.storage.enable_temporal!(types: [:T])).to be_nil
    value = g.for(viewer: Viewer.new(2), as_of: Date.new(1, 1, 1)).find(ref)
    expect([value.temporal?, value.valid_from, value.valid_to]).to eq([true, nil, nil])
    before = checks(g)
    expect(g.storage.sync_constraints!).to be_nil
    expect(checks(g)).to eq(before)
  end

  it "backfills after removing the old timeless check and scopes acknowledgement to the named types" do
    old = schema(temporal: [:T])
    old.storage.create!
    ref = seed(old, :U)
    g = schema(temporal: %i[T U])
    expect { g.storage.sync_constraints! }.to raise_error(Pglpg::TemporalMigrationRequired, /U/)
    expect { g.storage.enable_temporal!(types: [:T]) }.to raise_error(Pglpg::TemporalMigrationRequired, /U/)
    g.storage.enable_temporal!(types: [:U], backfill: ->(c) { c.execute("UPDATE temporal_migration_edges SET valid_from = DATE '2020-01-01' WHERE type = 'U'") })
    expect(g.for(viewer: Viewer.new(2), as_of: :any).find(ref).valid_from).to eq(Date.new(2020, 1, 1))
    g.storage.enable_temporal!(types: [:U])
    expect(g.for(viewer: Viewer.new(2), as_of: :any).find(ref).valid_from).to eq(Date.new(2020, 1, 1))
  end

  it "rolls columns, constraints and invalid backfill back without aborting caller work" do
    old = schema
    old.storage.create!
    seed(old)
    before = checks(old)
    g = schema(temporal: [:T])
    expect do
      g.storage.enable_temporal!(types: [:T], backfill: ->(c) { c.execute("UPDATE temporal_migration_edges SET valid_from = DATE '2021-01-01', valid_to = DATE '2020-01-01'") })
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect(columns(old)).not_to include("valid_from")
    expect(checks(old)).to eq(before)
    expect(old.connection.select_value("SELECT 1")).to eq(1)
    expect(seed(old)).to be_a(Pglpg::Ref)
  end

  it "requires a fresh acknowledgement after a digest changes, preserving finite bounds" do
    g = schema(temporal: [:T])
    g.storage.create!
    writer = g.for(viewer: Viewer.new(4))
    a = writer.insert_node(:P, attrs: { classification: 1 })
    ref = writer.insert_edge(:T, from: a, to: a, valid_from: Date.new(2020, 1, 1), attrs: { classification: 1 })
    name = checks(g).find { _1.include?("validity_T") }
    g.connection.execute("ALTER TABLE temporal_migration_edges RENAME CONSTRAINT #{g.connection.quote_column_name(name)} TO pglpg_temporal_migration_edges_old_marker")
    expect { g.storage.sync_constraints! }.to raise_error(Pglpg::TemporalMigrationRequired)
    g.storage.enable_temporal!(types: [:T])
    expect(g.for(viewer: Viewer.new(2), as_of: :any).find(ref).valid_from).to eq(Date.new(2020, 1, 1))
  end

  it "does not accept an unvalidated marker as proof of enablement" do
    g = schema(temporal: [:T])
    g.storage.create!
    writer = g.for(viewer: Viewer.new(4))
    a = writer.insert_node(:P, attrs: { classification: 1 })
    writer.insert_edge(:T, from: a, to: a, valid_from: nil, attrs: { classification: 1 })
    name, plan = g.storage.constraints.find { |name, _| name.include?("validity_T") }
    g.connection.execute("ALTER TABLE temporal_migration_edges DROP CONSTRAINT #{g.connection.quote_column_name(name)}")
    g.connection.execute(plan[:sql] + " NOT VALID")
    expect { g.storage.sync_constraints! }.to raise_error(Pglpg::TemporalMigrationRequired)
    g.storage.enable_temporal!(types: [:T])
    expect(g.connection.select_value("SELECT convalidated FROM pg_constraint WHERE conname = #{g.connection.quote(name)}")).to be(true)
  end

  it "retains physical columns when the final temporal type is disabled and refuses nonnull bounds" do
    g = schema(temporal: [:T])
    g.storage.create!
    writer = g.for(viewer: Viewer.new(4))
    a = writer.insert_node(:P, attrs: { classification: 1 })
    ref = writer.insert_edge(:T, from: a, to: a, valid_from: Date.new(2020, 1, 1), attrs: { classification: 1 })
    plain = schema
    expect { plain.storage.sync_constraints! }.to raise_error(ActiveRecord::StatementInvalid)
    writer.update_edge(ref, valid_from: nil)
    plain.storage.sync_constraints!
    expect(columns(plain)).to include("valid_from", "valid_to")
    expect { plain.storage.sync_constraints! }.not_to(change { checks(plain) })
  end

  it "refuses incompatible legacy bound columns without casting timestamps" do
    old = schema
    old.storage.create!
    old.connection.execute("ALTER TABLE temporal_migration_edges ADD COLUMN valid_from timestamp")
    expect { schema(temporal: [:T]).storage.enable_temporal!(types: [:T]) }.to raise_error(Pglpg::TemporalMigrationRequired, /nullable date/)
    expect(old.connection.columns(old.edges_table).find { _1.name == "valid_from" }.type).to eq(:datetime)
  end

  it "can roll back successful enablement with the outer transaction" do
    old = schema
    old.storage.create!
    seed(old)
    old.connection.transaction(requires_new: true) do
      schema(temporal: [:T]).storage.enable_temporal!(types: [:T])
      expect(columns(old)).to include("valid_from")
      raise ActiveRecord::Rollback
    end
    expect(columns(old)).not_to include("valid_from")
  end

  it "locks out inserts through the caller's outer commit, including an empty-type check", :committed do
    g = schema(temporal: [:T])
    g.storage.create!
    db = g.connection
    name = checks(g).find { _1.include?("validity_T") }
    db.execute("ALTER TABLE temporal_migration_edges DROP CONSTRAINT #{db.quote_column_name(name)}")
    node = g.for(viewer: Viewer.new(4)).insert_node(:P, attrs: { classification: 1 })
    attempted = Queue.new
    result = Queue.new
    observer = nil
    db.transaction do
      g.storage.sync_constraints! # type is empty, no acknowledgement needed
      observer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |other|
          other.transaction do
            other.execute("SET LOCAL lock_timeout = '100ms'")
            attempted << true
            begin
              other.execute("INSERT INTO temporal_migration_edges (type, source_id, target_id, classification) VALUES ('T', #{node.id}, #{node.id}, 1)")
              result << :inserted
            rescue ActiveRecord::LockWaitTimeout
              result << :blocked
            end
          end
        end
      end
      attempted.pop
      expect(result.pop).to eq(:blocked)
      observer.value
    end
    expect(seed(schema, :U)).to be_a(Pglpg::Ref)
  ensure
    observer&.join
    g&.storage&.drop!
  end
end
