# frozen_string_literal: true

RSpec.describe "Pglpg::Model associations" do
  let(:c) { ctx }
  let(:people) { ModelSpec::Person.in(c) }

  def schema(name, &) = Pglpg::Graph.define(name, &)

  def works_on(from, to, level = 1, **props)
    trusted.insert_edge(:WORKS_ON, from:, to:, properties: props, attrs: { classification: level })
  end

  def review(from, to, score, level = 1)
    trusted.insert_edge(:REVIEWED, from:, to:, properties: { score: }, attrs: { classification: level })
  end

  describe "declaring" do
    it "records associations, inherited by subclasses" do
      expect(ModelSpec::Person.associations.keys).to eq(%i[projects reviewed_projects known known_by friends])
      a = ModelSpec::Person.associations[:projects]
      expect([a.direction, a.edge_type, a.label]).to eq([:out, :WORKS_ON, :Project])
      expect(ModelSpec::Person.associations[:known_by].label).to eq(:Person)

      g = schema(:assoc_inherit) do
        node(:A)
        node(:B, extends: :A)
        edge(:L, from: :A, to: :A)
      end
      a = Class.new(Pglpg::Model::Node) do
        graph g, type: :A
        has_many :links, :out, edge: :L
      end
      b = Class.new(a) { graph g, type: :B }
      expect(b.associations.keys).to eq(%i[links])
    end

    it "checks direction, endpoints and names" do
      g = schema(:assoc_checks) do
        node(:P) { property :title, :string }
        node(:Q)
        node(:R)
        edge(:D, from: :P, to: :Q)
        edge(:S, from: :P, to: :Q, symmetric: true)
      end
      model = Class.new(Pglpg::Model::Node) { graph g, type: :P }

      expect { model.has_many :x, :both, edge: :D }.to raise_error(Pglpg::SchemaError, /D is directed/)
      expect { model.has_many :x, :out, edge: :S }.to raise_error(Pglpg::SchemaError, /S is symmetric/)
      expect { model.has_many :x, :in, edge: :D }.to raise_error(Pglpg::SchemaError, /P is not an endpoint of D \(in\)/)
      expect { model.has_many :x, :sideways, edge: :D }.to raise_error(ArgumentError, /direction/)
      expect { model.has_many :x, :out, edge: :NOPE }.to raise_error(ArgumentError, /unknown edge type/)
      expect { model.has_many :title, :out, edge: :D }.to raise_error(Pglpg::SchemaError, /title clashes/)
      expect { model.has_many :reload, :out, edge: :D }.to raise_error(Pglpg::SchemaError, /reload clashes/)
      expect { model.has_many :x, :both, edge: :S }.to raise_error(Pglpg::SchemaError, /S joins two labels; give label: or model:/)
      expect(model.has_many(:qs, :both, edge: :S, label: :Q).label).to eq(:Q)
      expect { Class.new(Pglpg::Model::Node).has_many :x, :out, edge: :D }.to raise_error(Pglpg::ConfigurationError, /declare graph/)
    end

    it "needs a target model at call time" do
      g = schema(:assoc_model) do
        column :classification, :integer
        node(:P)
        node(:Q)
        edge(:D, from: :P, to: :Q)
      end
      g.storage.create!
      p_model = Class.new(Pglpg::Model::Node) do
        graph g, type: :P
        has_many :qs, :out, edge: :D
        has_many :ps, :out, edge: :D, model: "String"
      end
      gctx = g.for(viewer: Viewer.new(4))
      record = p_model.in(gctx).create!(classification: 1)

      expect { record.qs }.to raise_error(Pglpg::ConfigurationError, /no node model of graph assoc_model for Q; give model:/)
      expect { record.ps }.to raise_error(Pglpg::ConfigurationError, /no node model/)
    end
  end

  describe "target queries" do
    let(:ann) { people.find(person(1, name: "Ann")) }

    it "returns each visible target once, deduplicated before pagination and counts" do
      apollo = project(1, title: "Apollo")
      gemini = project(1, title: "Gemini")
      zeus = project(1, title: "Zeus")
      [apollo, apollo, apollo, gemini, zeus].each_with_index { |j, i| review(ann.ref, j, i) }

      reviewed = ann.reviewed_projects
      expect(reviewed.order(:title).map(&:title)).to eq(%w[Apollo Gemini Zeus])
      expect(reviewed.count).to eq(3)
      expect(reviewed.order(:title).limit(2).map(&:title)).to eq(%w[Apollo Gemini])
      expect(reviewed.order(:title).offset(1).limit(1).map(&:title)).to eq(%w[Gemini])
      expect(reviewed.order(:title).limit(2).count).to eq(2)
      expect(reviewed.where(title: "Zeus").exists?).to be(true)
      expect(reviewed.order(title: :desc).first.title).to eq("Zeus")
      expect(reviewed.first).to be_a(ModelSpec::Project)
    end

    it "reads edge conditions as 'at least one matching visible edge'" do
      apollo = project(1, title: "Apollo")
      gemini = project(1, title: "Gemini")
      review(ann.ref, apollo, 1)
      review(ann.ref, apollo, 5)
      review(ann.ref, gemini, 2)
      review(ann.ref, gemini, 9, 3) # hidden at clearance 2

      high = ModelSpec::Person.in(ctx(2)).find(ann.ref).reviewed_projects.rel_where(score: Pglpg.gte(5))
      expect(high.map(&:title)).to eq(%w[Apollo])
      expect(high.count).to eq(1)
    end

    it "refuses to order targets by an edge property" do
      expect { ann.reviewed_projects.rel_order(:score) }.to raise_error(ArgumentError, /use with_rel.rel_order/)
    end

    it "follows incoming and symmetric edges" do
      bob = people.find(person(1, name: "Bob"))
      cid = people.find(person(1, name: "Cid"))
      trusted.insert_edge(:KNOWS, from: bob.ref, to: ann.ref, attrs: { classification: 1 })
      trusted.insert_edge(:FRIEND, from: cid.ref, to: ann.ref, attrs: { classification: 1 })
      trusted.insert_edge(:FRIEND, from: ann.ref, to: bob.ref, attrs: { classification: 1 })

      expect(ann.known_by.map(&:name)).to eq(%w[Bob])
      expect(ann.known.to_a).to eq([])
      expect(ann.friends.order(:name).map(&:name)).to eq(%w[Bob Cid])
      expect(cid.friends.map(&:name)).to eq(%w[Ann])
    end

    it "applies visibility to the owner, the edges and the targets" do
      low = project(1, title: "Low")
      high = project(3, title: "High")
      works_on(ann.ref, low)
      works_on(ann.ref, high)
      hidden_edge_target = project(1, title: "Edge")
      works_on(ann.ref, hidden_edge_target, 3)

      expect(ModelSpec::Person.in(ctx(2)).find(ann.ref).projects.map(&:title)).to eq(%w[Low])

      # A loaded owner that is hidden afterwards has no visible targets.
      bob = ModelSpec::Person.in(ctx(2)).find(person(2))
      works_on(bob.ref, low)
      expect(bob.projects.count).to eq(1)
      trusted.update_node(bob.ref, attrs: { classification: 3 })
      expect(bob.projects.count).to eq(0)
    end

    it "loads targets as their registered models" do
      emp = trusted.insert_node(:Employee, properties: { uid: "E-1", name: "Eve" }, attrs: { classification: 1 })
      trusted.insert_edge(:KNOWS, from: ann.ref, to: emp, attrs: { classification: 1 })
      eve = ann.known.first
      expect([eve.class, eve.schema_type.name]).to eq([ModelSpec::Person, :Employee])
    end

    it "needs a saved owner, and doesn't build through associations" do
      expect { people.new.projects }.to raise_error(ArgumentError, /save the record first/)
      expect { ann.projects.new }.to raise_error(ArgumentError, /can't build records yet/)
      expect { ann.projects.create!(title: "X") }.to raise_error(ArgumentError, /can't build records yet/)
      expect { ann.projects.find(project(1)) }.to raise_error(ArgumentError, /find ignores/)
    end
  end

  describe "binding queries" do
    let(:ann) { people.find(person(1, name: "Ann")) }

    it "returns one row per node–edge pair" do
      apollo = project(1, title: "Apollo")
      gemini = project(1, title: "Gemini")
      r1 = review(ann.ref, apollo, 1)
      r2 = review(ann.ref, apollo, 5)
      r3 = review(ann.ref, gemini, 2)

      pairs = ann.reviewed_projects.with_rel
      expect(pairs.count).to eq(3)
      expect(pairs.order(:title).rel_order(:score).map { |j, r| [j.title, r.ref] })
        .to eq([["Apollo", r1], ["Apollo", r2], ["Gemini", r3]])
      expect(pairs.rel_order(score: :desc).limit(2).map { _2.score }).to eq([5, 2])
      expect(pairs.rel_where(score: Pglpg.lt(5)).count).to eq(2)
      expect(pairs.first.map(&:class)).to eq([ModelSpec::Project, ModelSpec::Reviewed])

      seen = []
      ann.reviewed_projects.where(title: "Apollo").each_with_rel { |j, r| seen << [j.title, r.score] }
      expect(seen).to contain_exactly(["Apollo", 1], ["Apollo", 5])
    end

    it "is only built before order, limit or offset" do
      %i[order limit offset].each do |m|
        arg = m == :order ? :title : 1
        expect { ann.reviewed_projects.public_send(m, arg).with_rel }.to raise_error(ArgumentError, /before order, limit or offset/)
      end
      expect(ann.reviewed_projects.where(title: "X").with_rel.count).to eq(0)
    end

    it "needs an edge model" do
      g = schema(:assoc_edge) do
        column :classification, :integer
        node(:P)
        edge(:D, from: :P, to: :P)
      end
      g.storage.create!
      model = Class.new(Pglpg::Model::Node) do
        graph g, type: :P
        has_many :ds, :out, edge: :D
      end
      w = g.for(viewer: Viewer.new(4))
      Pglpg.configuration.trusted_writer_allowed = ->(_) { true }
      a = w.trusted_writer.insert_node(:P, attrs: { classification: 1 })
      w.trusted_writer.insert_edge(:D, from: a, to: a, attrs: { classification: 1 })

      record = model.in(w).find(a)
      expect(record.ds.map(&:id)).to eq([a.id])
      expect { record.ds.with_rel.to_a }.to raise_error(Pglpg::ConfigurationError, /no model is registered for edge type D/)
    end
  end
end
