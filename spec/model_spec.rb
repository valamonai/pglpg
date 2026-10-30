# frozen_string_literal: true

RSpec.describe Pglpg::Model do
  let(:people) { ModelSpec::Person.in(ctx) }

  # A graph that is only defined, never stored: for declaration errors.
  def schema(name = :model_schema, &) = Pglpg::Graph.define(name, &)

  describe "declaring a model" do
    it "takes its attributes from the schema type and the application columns" do
      expect(ModelSpec::Person.property_names).to eq(%i[uid name rank born tags status])
      expect(ModelSpec::Person.column_names).to eq(%i[classification])
      expect(ModelSpec::Person.attribute_names).to eq(%w[uid name rank born tags status classification])
      expect(ModelSpec::WorksOn.attribute_names).to eq(%w[role since classification])
      expect(ModelSpec::Person.graph).to be(Kg)
    end

    it "assigns attributes as given, without form coercion" do
      person = ModelSpec::Person.new(rank: "42")
      expect(person.rank).to eq("42")
      expect(person).to be_new_record
      expect(person.ref).to be_nil
    end

    it "rejects a second model for the same type" do
      expect { Class.new(Pglpg::Model::Node) { graph Kg, type: :Person } }
        .to raise_error(Pglpg::ConfigurationError, /Person in graph spec_kg already has a model/)
    end

    it "lets a reloaded class of the same name replace the earlier one" do
      g = schema { node(:Thing) { property :title, :string } }
      first = Class.new(Pglpg::Model::Node) { def self.name = "Thing" }
      second = Class.new(Pglpg::Model::Node) { def self.name = "Thing" }
      first.graph(g, type: :Thing)
      second.graph(g, type: :Thing)
      expect(Pglpg::Model.lookup(g, :node, :Thing)).to be(second)
    end

    it "rejects binding twice" do
      g = schema { node(:Thing) }
      model = Class.new(Pglpg::Model::Node) { graph g, type: :Thing }
      expect { model.graph(g, type: :Thing) }.to raise_error(Pglpg::ConfigurationError, /already bound/)
    end

    it "rejects unknown types" do
      expect { Class.new(Pglpg::Model::Node) { graph Kg, type: :Nope } }.to raise_error(ArgumentError, /unknown node type/)
      expect { Class.new(Pglpg::Model::Edge) { graph Kg, type: :Person } }.to raise_error(ArgumentError, /unknown edge type/)
    end

    it "rejects a property named like an application column" do
      g = schema do
        node_column :rank, :integer
        node(:Thing) { property :rank, :integer }
      end
      expect { Class.new(Pglpg::Model::Node) { graph g, type: :Thing } }
        .to raise_error(Pglpg::SchemaError, /properties named like columns: rank/)
    end

    it "rejects properties that clash with model methods" do
      %i[ref labels errors hash].each do |name|
        g = schema(:"clash_#{name}") { node(:Thing) { property name, :string } }
        expect { Class.new(Pglpg::Model::Node) { graph g, type: :Thing } }
          .to raise_error(Pglpg::SchemaError, /Thing.#{name} clashes with a method/)
      end
    end

    it "rejects properties that clash with private model methods" do
      %i[load_element load_identity attribute].each do |name|
        g = schema(:"private_#{name}") { node(:Thing) { property name, :string } }
        expect { Class.new(Pglpg::Model::Node) { graph g, type: :Thing } }
          .to raise_error(Pglpg::SchemaError, /Thing.#{name} clashes with a method/)
      end
      g = schema(:private_edge) do
        node(:Thing)
        edge(:LINK, from: :Thing, to: :Thing) { property :load_identity, :string }
      end
      expect { Class.new(Pglpg::Model::Edge) { graph g, type: :LINK } }
        .to raise_error(Pglpg::SchemaError, /LINK.load_identity clashes with a method/)
    end

    it "allows properties named like private Kernel methods" do
      g = schema { node(:Thing) { property :format, :string } }
      model = Class.new(Pglpg::Model::Node) { graph g, type: :Thing }
      expect(model.new(format: "pdf").format).to eq("pdf")
    end

    it "extends another model only along the schema's inheritance" do
      g = schema do
        node(:Base) { property :uid, :string }
        node(:Sub, extends: :Base)
        node(:Other)
      end
      base = Class.new(Pglpg::Model::Node) { graph g, type: :Base }
      expect(Class.new(base) { graph g, type: :Sub }.attribute_names).to eq(%w[uid])
      expect { Class.new(base) { graph g, type: :Other } }.to raise_error(Pglpg::SchemaError, /cannot extend/)
    end

    it "checks inheritance against the nearest bound ancestor model" do
      g = schema(:model_chain) do
        node(:Base) { property :uid, :string }
        node(:Sub, extends: :Base)
        node(:Other) { property :title, :string }
      end
      base = Class.new(Pglpg::Model::Node) { graph g, type: :Base }
      intermediate = Class.new(base)
      expect { Class.new(intermediate) { graph g, type: :Other } }.to raise_error(Pglpg::SchemaError, /cannot extend/)
      expect(Class.new(intermediate) { graph g, type: :Sub }.attribute_names).to eq(%w[uid])
    end
  end

  describe ".in" do
    it "needs a context of the model's graph" do
      other = schema(:model_other) { node(:Person) }
      expect { ModelSpec::Person.in(other.for(viewer: Viewer.new(4))) }.to raise_error(ArgumentError, /graph model_other/)
      expect { ModelSpec::Person.in(Viewer.new(4)) }.to raise_error(ArgumentError, /Pglpg::Context/)
    end

    it "needs a bound model" do
      expect { Class.new(Pglpg::Model::Node).in(ctx) }.to raise_error(Pglpg::ConfigurationError, /not bound/)
    end
  end

  describe "reading nodes" do
    it "loads properties, columns and identity" do
      ref = person(2, name: "Ann", rank: 3, born: Date.new(1990, 1, 2), tags: %w[a b], status: "active")
      ann = people.find(ref)

      expect(ann).to be_a(ModelSpec::Person)
      expect(ann).to be_persisted
      expect(ann.changed?).to be(false) if ann.respond_to?(:changed?)
      expect(ann.ref).to eq(ref)
      expect(ann.id).to eq(ref.id)
      expect(ann.context).to be(people.context)
      expect([ann.name, ann.rank, ann.born, ann.tags, ann.status]).to eq(["Ann", 3, Date.new(1990, 1, 2), %w[a b], "active"])
      expect(ann.classification).to eq(2)
      expect(ann.key).to eq(ann.uid)
      expect(ann.schema_type.name).to eq(:Person)
      expect(ann.labels).to eq(%i[Agent Person])
      expect(ann.created_at).to be_a(Time)
      expect(ann.extra_properties).to eq({})
      expect(ann.to_param).to eq(ref.to_s)
      expect(ann.to_key).to eq([ref.id])
    end

    it "builds a registered subtype's model, else the queried model" do
      ref = person(1, name: "Ann")
      emp = trusted.insert_node(:Employee, properties: { uid: "E-1", name: "Eve", salary: BigDecimal("10.5") },
                                           attrs: { classification: 1 })

      # "E-1" sorts before "P-…": the Employee has no model, so it loads as
      # the queried Agent; the Person loads as its registered model.
      agents = ModelSpec::Agent.in(ctx).order(:uid).to_a
      expect(agents.map { [_1.class, _1.schema_type.name] })
        .to eq([[ModelSpec::Agent, :Employee], [ModelSpec::Person, :Person]])
      expect(agents.first.extra_properties.keys).to eq(%i[name salary])

      eve = people.find(emp)
      expect(eve).to be_a(ModelSpec::Person)
      expect(eve.schema_type.name).to eq(:Employee)
      expect(eve.name).to eq("Eve")
      expect(eve.extra_properties).to eq(salary: BigDecimal("10.5"))
      expect(people.find(ref).schema_type.name).to eq(:Person)
    end

    it "filters, orders and paginates" do
      %w[Cid Ann Bob].each_with_index { |name, i| person(1, name:, rank: i) }
      person(1, name: "Dee", rank: 9)

      expect(people.order(:name).map(&:name)).to eq(%w[Ann Bob Cid Dee])
      expect(people.order(name: :desc).limit(2).map(&:name)).to eq(%w[Dee Cid])
      expect(people.order(:name).offset(1).limit(2).map(&:name)).to eq(%w[Bob Cid])
      expect(people.where(rank: Pglpg.gte(1)).order(rank: :desc).map(&:name)).to eq(%w[Dee Bob Ann])
      expect(people.where(name: "Bob").count).to eq(1)
      expect(people.where(name: "Zed").exists?).to be(false)
      expect(people.order(:name).first.name).to eq("Ann")
      expect(people.order(:name).first(2).map(&:name)).to eq(%w[Ann Bob])
      expect(people.find_by(name: "Cid").rank).to eq(0)
      expect(people.find_by(name: "Zed")).to be_nil
    end

    it "rejects conditions on undeclared properties" do
      expect { people.where(salary: 1) }.to raise_error(ArgumentError, /Person has no property :salary/)
    end

    it "applies the visibility policy" do
      person(1, name: "Low")
      high = person(3, name: "High")

      low_view = ModelSpec::Person.in(ctx(2))
      expect(low_view.map(&:name)).to eq(%w[Low])
      expect(low_view.count).to eq(1)
      expect(low_view.find_by(name: "High")).to be_nil
      expect { low_view.find(high) }.to raise_error(Pglpg::Model::RecordNotFound)
    end

    it "makes missing, hidden and wrong-type lookups look the same" do
      hidden = person(3)
      missing = Kg.ref(:node, 999_999_999)
      other = project(1)

      [hidden, missing, other].each do |ref|
        expect { ModelSpec::Person.in(ctx(2)).find(ref) }.to raise_error(Pglpg::Model::RecordNotFound, "record not found")
      end
    end

    it "finds by the String form of a ref" do
      ref = person(1, name: "Ann")
      expect(people.find(ref.to_s).name).to eq("Ann")
      expect { people.find("spec_kg:node:x") }.to raise_error(Pglpg::InvalidRef)
    end

    it "rejects refs of the wrong kind or graph" do
      edge = trusted.insert_edge(:KNOWS, from: person, to: person, attrs: { classification: 1 })
      expect { people.find(edge) }.to raise_error(Pglpg::InvalidRef, /expected a node ref/)
      expect { people.find(Pglpg::Ref.new(graph: :other, kind: :node, id: 1)) }.to raise_error(Pglpg::InvalidRef)
    end

    it "refuses find on a filtered relation" do
      expect { people.where(name: "Ann").find(person) }.to raise_error(ArgumentError, /find ignores conditions/)
    end

    it "compares records by ref" do
      ref = person(1)
      expect(people.find(ref)).to eq(ModelSpec::Agent.in(ctx).find(ref))
      expect(people.find(ref).hash).to eq(people.find(ref).hash)
      expect(ModelSpec::Person.new).not_to eq(ModelSpec::Person.new)
    end
  end

  describe "reading edges" do
    it "loads properties, columns and endpoints" do
      ann = person(1)
      apollo = project(1, title: "Apollo")
      ref = trusted.insert_edge(:WORKS_ON, from: ann, to: apollo, properties: { role: "lead" }, attrs: { classification: 2 })

      w = ModelSpec::WorksOn.in(ctx).find(ref)
      expect(w).to be_a(ModelSpec::WorksOn)
      expect([w.role, w.classification, w.source, w.target]).to eq(["lead", 2, ann, apollo])
      expect(w).not_to be_symmetric
      expect(w.other(ann)).to eq(apollo)
    end

    it "filters and orders edges" do
      a = person(1)
      %w[dev lead ops].each { |role| trusted.insert_edge(:WORKS_ON, from: a, to: project(1), properties: { role: }, attrs: { classification: 1 }) }

      works = ModelSpec::WorksOn.in(ctx)
      expect(works.order(role: :desc).map(&:role)).to eq(%w[ops lead dev])
      expect(works.where(role: "lead").count).to eq(1)
      expect(works.count).to eq(3)
    end

    it "returns each symmetric edge once" do
      a = person(1)
      b = person(1)
      c = person(1)
      ab = trusted.insert_edge(:FRIEND, from: b, to: a, attrs: { classification: 1 })
      bc = trusted.insert_edge(:FRIEND, from: b, to: c, attrs: { classification: 1 })

      friends = ModelSpec::Friend.in(ctx)
      expect(friends.map(&:ref)).to eq([ab, bc])
      expect(friends.count).to eq(2)
      expect(friends.find(ab)).to be_symmetric
    end

    it "hides edges with a hidden endpoint or classification" do
      low = person(1)
      high = person(3)
      e1 = trusted.insert_edge(:KNOWS, from: low, to: low, attrs: { classification: 3 })
      e2 = trusted.insert_edge(:WORKS_ON, from: high, to: project(1), attrs: { classification: 1 })

      expect { ModelSpec::WorksOn.in(ctx(2)).find(e2) }.to raise_error(Pglpg::Model::RecordNotFound)
      expect(ModelSpec::WorksOn.in(ctx(2)).count).to eq(0)
      expect { ModelSpec::WorksOn.in(ctx(2)).find(e1) }.to raise_error(Pglpg::Model::RecordNotFound)
    end
  end
end
