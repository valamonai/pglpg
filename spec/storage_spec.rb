# frozen_string_literal: true

RSpec.describe Pglpg::Storage do
  let(:conn) { ActiveRecord::Base.connection }
  let(:nodes) { Kg.nodes_table }
  let(:edges) { Kg.edges_table }

  def insert_raw(key_label, labels, properties, classification: 1)
    conn.select_value(<<~SQL)
      INSERT INTO #{nodes} (key_label, labels, properties, classification)
      VALUES (#{conn.quote(key_label)}, #{conn.quote("{#{labels.join(",")}}")}::text[], #{conn.quote(JSON.generate(properties))}::jsonb, #{classification})
      RETURNING id
    SQL
  end

  def raw_violation
    conn.transaction(requires_new: true) { yield }
    nil
  rescue ActiveRecord::StatementInvalid => e
    e.cause.class
  end

  describe "typed required-key checks" do
    it "rejects a missing key, JSON null and the wrong type, and accepts a valid value" do
      expect(raw_violation { insert_raw("Project", ["Project"], { "title" => "t" }) }).to eq(PG::CheckViolation)
      expect(raw_violation { insert_raw("Project", ["Project"], { "uid" => nil, "title" => "t" }) })
        .to eq(PG::CheckViolation)
      expect(raw_violation { insert_raw("Project", ["Project"], { "uid" => 42, "title" => "t" }) })
        .to eq(PG::CheckViolation)
      expect(raw_violation { insert_raw("Project", ["Project"], { "uid" => "J-1", "title" => "t" }) }).to be_nil
    end

    it "applies inherited required properties through the parent label" do
      expect(raw_violation { insert_raw("Employee", %w[Agent Employee Person], {}) }).to eq(PG::CheckViolation)
    end

    it "checks required edge properties" do
      a = insert_raw("Person", %w[Agent Person], { "uid" => "a" })
      b = insert_raw("Project", ["Project"], { "uid" => "b", "title" => "t" })
      sql = "INSERT INTO #{edges} (type, source_id, target_id, properties, classification) VALUES ('REVIEWED', #{a}, #{b}, '{}', 1)"
      expect(raw_violation { conn.execute(sql) }).to eq(PG::CheckViolation)
    end
  end

  describe "key uniqueness" do
    it "spans a type and all its subtypes" do
      insert_raw("Person", %w[Agent Person], { "uid" => "same" })
      expect(raw_violation { insert_raw("Employee", %w[Agent Employee Person], { "uid" => "same" }) })
        .to eq(PG::UniqueViolation)
    end

    it "is separate per key-declaring type" do
      insert_raw("Person", %w[Agent Person], { "uid" => "same" })
      expect(raw_violation { insert_raw("Project", ["Project"], { "uid" => "same", "title" => "t" }) }).to be_nil
    end
  end

  it "enforces pair uniqueness only for declared edge types" do
    a = insert_raw("Person", %w[Agent Person], { "uid" => "a" })
    b = insert_raw("Project", ["Project"], { "uid" => "b", "title" => "t" })
    edge = ->(type) { conn.execute("INSERT INTO #{edges} (type, source_id, target_id, classification) VALUES ('#{type}', #{a}, #{b}, 1)") }
    edge.call("WORKS_ON")
    expect(raw_violation { edge.call("WORKS_ON") }).to eq(PG::UniqueViolation)
    expect(raw_violation { 2.times { conn.execute("INSERT INTO #{edges} (type, source_id, target_id, properties, classification) VALUES ('REVIEWED', #{a}, #{b}, '{\"score\": 1}', 1)") } }).to be_nil
  end

  it "restricts deleting nodes that have edges" do
    a = insert_raw("Person", %w[Agent Person], { "uid" => "a" })
    b = insert_raw("Project", ["Project"], { "uid" => "b", "title" => "t" })
    conn.execute("INSERT INTO #{edges} (type, source_id, target_id, classification) VALUES ('WORKS_ON', #{a}, #{b}, 1)")
    # PostgreSQL 18 reports RESTRICT as restrict_violation (23001), older versions as foreign_key_violation.
    expect(raw_violation { conn.execute("DELETE FROM #{nodes} WHERE id = #{a}") })
      .to eq(PG::ForeignKeyViolation).or eq(PG::RestrictViolation)
  end

  it "requires the key label to be among the labels" do
    expect(raw_violation { insert_raw("Person", ["Agent"], { "uid" => "a" }) }).to eq(PG::CheckViolation)
  end

  it "syncs constraints idempotently and drops stale ones" do
    expect { Kg.storage.sync_constraints! }.not_to(change { constraint_names })
    conn.execute("CREATE UNIQUE INDEX pglpg_#{nodes}_stale_x ON #{nodes} ((properties->>'x'))")
    Kg.storage.sync_constraints!
    expect(constraint_names).not_to include("pglpg_#{nodes}_stale_x")
    expect(constraint_names.size).to eq(Kg.storage.constraints.size)
  end

  describe "labels" do
    it "reports drift and relabels" do
      ok = insert_raw("Employee", %w[Agent Employee Person], { "uid" => "e1" })
      # As if Agent had become a parent of Person after this row was written.
      missing = insert_raw("Employee", %w[Employee Person], { "uid" => "e2" })
      extra = insert_raw("Person", %w[Agent Extra Person], { "uid" => "p1" })
      expect(Kg.storage.label_drift).to eq(Employee: 1, Person: 1)
      expect(Kg.storage.relabel!).to eq(2)
      expect(Kg.storage.label_drift).to eq({})
      labels = conn.select_values("SELECT labels::text FROM #{nodes} WHERE id IN (#{ok}, #{missing}, #{extra}) ORDER BY id")
      expect(labels).to eq(["{Agent,Employee,Person}", "{Agent,Employee,Person}", "{Agent,Person}"])
    end

    it "counts rows of unknown types as drift" do
      insert_raw("Ghost", ["Ghost"], {})
      expect(Kg.storage.label_drift).to eq(Ghost: 1)
    end
  end

  def constraint_names
    conn.select_values(<<~SQL)
      SELECT conname FROM pg_constraint WHERE conname LIKE 'pglpg\\_%'
      UNION SELECT indexname FROM pg_indexes WHERE indexname LIKE 'pglpg\\_%' ORDER BY 1
    SQL
  end
end
