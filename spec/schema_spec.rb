# frozen_string_literal: true

RSpec.describe "graph type DSL" do
  def define(&) = Pglpg::Graph.define(:schema_test, &)

  it "derives sorted label sets from inheritance" do
    expect(Kg.type.node_type!(:Employee).labels).to eq(%w[Agent Employee Person])
    expect(Kg.type.node_type!(:Project).labels).to eq(%w[Project])
  end

  it "inherits properties and the key" do
    employee = Kg.type.node_type!(:Employee)
    expect(employee.properties.keys).to include(:uid, :name, :salary)
    expect(employee.key.property).to eq(:uid)
    expect(employee.key.declared_on).to eq(:Agent)
  end

  it "supports multiple inheritance" do
    g = define do
      node(:A) { property :a, :string }
      node(:B) { property :b, :integer }
      node :C, extends: %i[A B]
    end
    expect(g.type.node_type!(:C).labels).to eq(%w[A B C])
    expect(g.type.node_type!(:C).properties.keys).to contain_exactly(:a, :b)
  end

  it "rejects invalid declarations" do
    expect { define { node :A, extends: :Missing } }.to raise_error(Pglpg::SchemaError, /unknown node type/)
    expect { define { node(:A, extends: :B); node(:B, extends: :A) } }.to raise_error(Pglpg::SchemaError, /cycle/)
    expect { define { node(:A) { key :uid } } }.to raise_error(Pglpg::SchemaError, /not a declared property/)
    expect { define { node(:A) { property :uid, :string; key :uid } } }.to raise_error(Pglpg::SchemaError, /required/)
    expect { define { node(:A) { property :n, :integer, required: true; key :n } } }
      .to raise_error(Pglpg::SchemaError, /string/)
    expect { define { node(:A) { property :x, :blob } } }.to raise_error(Pglpg::SchemaError, /unknown property type/)
    expect { define { node(:A) { property :x, :enum } } }.to raise_error(Pglpg::SchemaError, /values/)
    expect { define { node(:A); node(:A) } }.to raise_error(Pglpg::SchemaError, /twice/)
    expect { define { node(:A); edge :E, from: :A, to: :Z } }.to raise_error(Pglpg::SchemaError, /unknown node type Z/)
    expect { define { node(:A); edge :E, from: :A, to: :A, symmetric: true } }.to raise_error(Pglpg::SchemaError, /0.2/)
    expect { define { node(:A); edge :E, from: :A, to: :A, temporal: true } }.to raise_error(Pglpg::SchemaError, /0.3/)
    expect { define { node_column :labels, :string } }.to raise_error(Pglpg::SchemaError, /reserved/)
    expect { define { node "bad name" } }.to raise_error(Pglpg::SchemaError, /invalid/)
  end

  it "rejects two keys in one ancestry" do
    expect do
      define do
        node(:A) { property(:a, :string, required: true); key :a }
        node(:B, extends: :A) { property(:b, :string, required: true); key :b }
      end
    end.to raise_error(Pglpg::SchemaError, /more than one key/)
  end

  it "rejects conflicting inherited definitions" do
    expect do
      define do
        node(:A) { property :x, :string }
        node(:B) { property :x, :integer }
        node :C, extends: %i[A B]
      end
    end.to raise_error(Pglpg::SchemaError, /conflicting/)
  end

  describe "property values" do
    let(:person) { Kg.type.node_type!(:Person) }

    it "validates and encodes typed values, dropping nil" do
      json = person.encode_properties({ uid: "u", rank: 3, born: Date.new(2000, 1, 2), tags: %w[a b], status: :active,
                                        name: nil })
      expect(json).to eq("uid" => "u", "rank" => 3, "born" => "2000-01-02", "tags" => %w[a b], "status" => "active")
    end

    it "rejects undeclared properties, wrong types and missing required values" do
      expect { person.encode_properties({ uid: "u", nope: 1 }) }.to raise_error(Pglpg::ValidationError, /nope/)
      expect { person.encode_properties({ uid: "u", rank: "3" }) }.to raise_error(Pglpg::ValidationError, /integer/)
      expect { person.encode_properties({ uid: "u", status: "gone" }) }.to raise_error(Pglpg::ValidationError, /enum/)
      expect { person.encode_properties({ uid: "u", tags: [1] }) }.to raise_error(Pglpg::ValidationError)
      expect { person.encode_properties({ name: "x" }) }.to raise_error(Pglpg::ValidationError, /uid is required/)
      expect { person.encode_properties({ name: "x" }, partial: true) }.not_to raise_error
      expect { person.encode_properties({ uid: nil }, partial: true) }.to raise_error(Pglpg::ValidationError)
    end

    it "round-trips decimal and datetime values" do
      t = Time.utc(2026, 1, 2, 3, 4, 5.123456r)
      project = Kg.type.node_type!(:Project)
      json = project.encode_properties({ uid: "u", title: "t", started_at: t })
      expect(project.decode_properties(JSON.parse(JSON.generate(json)))[:started_at]).to eq(t)
      employee = Kg.type.node_type!(:Employee)
      json = employee.encode_properties({ uid: "u", salary: BigDecimal("1.50") })
      expect(json["salary"]).to eq("1.5")
      expect(employee.decode_properties(json)[:salary]).to eq(BigDecimal("1.5"))
    end
  end
end

RSpec.describe Pglpg::Ref do
  it "is immutable and graph-scoped" do
    ref = Kg.ref(:node, 7)
    expect(ref).to be_frozen
    expect(ref.to_s).to eq("spec_kg:node:7")
    expect(Kg.parse_ref("spec_kg:node:7")).to eq(ref)
    expect { Kg.parse_ref("other:node:7") }.to raise_error(Pglpg::InvalidRef)
    expect { Kg.parse_ref("spec_kg:node:x") }.to raise_error(Pglpg::InvalidRef)
    expect { Kg.parse_ref("spec_kg:thing:1") }.to raise_error(Pglpg::InvalidRef)
    expect { Kg.ref(:node, 0) }.to raise_error(ArgumentError)
  end

  it "is checked for graph and kind" do
    expect { Kg.check_ref!(Pglpg::Ref.new(graph: :other, kind: :node, id: 1), :node) }
      .to raise_error(Pglpg::InvalidRef, /graph other/)
    expect { Kg.check_ref!(Kg.ref(:edge, 1), :node) }.to raise_error(Pglpg::InvalidRef, /node ref/)
    expect { Kg.check_ref!(1, :node) }.to raise_error(Pglpg::InvalidRef)
  end
end
