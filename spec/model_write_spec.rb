# frozen_string_literal: true

RSpec.describe "Pglpg::Model writes" do
  let(:c) { ctx }
  let(:people) { ModelSpec::Person.in(c) }
  let(:projects) { ModelSpec::Project.in(c) }

  def stored(ref) = Kg.for(viewer: Viewer.new(4)).find(ref)

  describe "creating nodes" do
    it "inserts the assigned values and generates the key" do
      ann = people.create!(name: "Ann", rank: 2, born: Date.new(1990, 1, 2), classification: 1)

      expect(ann).to be_persisted
      expect(ann.changed?).to be(false)
      expect(ann.context).to be(c)
      expect(stored(ann.ref).properties).to include(name: "Ann", rank: 2, born: Date.new(1990, 1, 2))
      # Local state is what was assigned: the generated key arrives on reload.
      expect(ann.uid).to be_nil
      expect(ann.created_at).to be_nil
      expect(ann.reload.uid).to eq(stored(ann.ref)[:uid])
      expect(ann.created_at).to be_a(Time)
    end

    it "validates values strictly against the schema" do
      person = people.new(rank: "42", tags: "a", status: "gone", classification: 1)

      expect(person.save).to be(false)
      expect(person.errors.to_hash).to eq(
        rank: ["is not a valid integer"], tags: ["is not a valid list of string"], status: ["is not a valid enum"]
      )
      expect(person).to be_new_record
      expect(people.count).to eq(0)
    end

    it "requires required properties and columns" do
      project = projects.new
      expect(project).not_to be_valid
      expect(project.errors.to_hash).to eq(title: ["can't be blank"], classification: ["can't be blank"])
    end

    it "rejects an assigned key, also with the trusted writer" do
      person = people.new(uid: "P-1", classification: 1)
      expect(person.save(writer: c.trusted_writer)).to be(false)
      expect(person.errors[:uid]).to eq(["is generated and cannot be assigned"])
    end

    it "refuses abstract types" do
      agent = ModelSpec::Agent.in(c).new(classification: 1)
      expect(agent).not_to be_valid
      expect(agent.errors[:base]).to eq(["Agent is abstract"])
    end

    it "raises RecordInvalid from save! and create!" do
      expect { people.create!(rank: "x", classification: 1) }.to raise_error(Pglpg::Model::RecordInvalid, /Rank is not a valid integer/) do |e|
        expect(e.record.errors[:rank]).to be_present
      end
    end

    it "returns an unsaved record from create when validation fails" do
      person = people.create(rank: "x", classification: 1)
      expect(person).to be_new_record
      expect(person.errors[:rank]).to be_present
    end

    it "keeps the record new and its changes when the write policy refuses" do
      person = ModelSpec::Person.in(ctx(2)).new(name: "Ann", classification: 3)
      expect { person.save }.to raise_error(Pglpg::WriteRejected)
      expect(person).to be_new_record
      expect(person.changes).to include("name" => [nil, "Ann"])
    end

    it "needs a context" do
      expect { ModelSpec::Person.new(name: "Ann").save }.to raise_error(ArgumentError, /no context/)
    end
  end

  describe "updating nodes" do
    it "sends only the changed attributes, merging with concurrent changes" do
      ann = people.find(person(1, name: "Ann", rank: 1))
      trusted.update_node(ann.ref, properties: { rank: 7 })

      ann.name = "Anne"
      expect(ann.changed).to eq(%w[name])
      expect(ann.save).to be(true)
      expect(ann.changed?).to be(false)
      expect(stored(ann.ref).properties).to include(name: "Anne", rank: 7)
    end

    it "removes a property set to nil" do
      ann = people.find(person(1, name: "Ann", rank: 1))
      ann.rank = nil
      ann.save!
      expect(stored(ann.ref).properties).not_to have_key(:rank)
    end

    it "keeps keys and required values" do
      ann = people.find(person(1))
      ann.uid = "P-other"
      expect(ann.save).to be(false)
      expect(ann.errors[:uid]).to eq(["cannot be changed"])

      apollo = projects.find(project(1, title: "Apollo"))
      apollo.title = nil
      apollo.classification = nil
      expect(apollo).not_to be_valid
      expect(apollo.errors.to_hash).to eq(title: ["can't be blank"], classification: ["can't be blank"])
    end

    it "runs no statement without changes" do
      ref = person(2, name: "Ann")
      ann = ModelSpec::Person.in(ctx(2)).find(ref)
      trusted.update_node(ref, attrs: { classification: 3 })

      expect(ann.save).to be(true)
      ann.name = "Anne"
      expect { ann.save }.to raise_error(Pglpg::WriteRejected, "write rejected")
      expect(ann.changes).to eq("name" => %w[Ann Anne])
    end

    it "makes hidden and missing targets look the same" do
      hidden = ModelSpec::Person.in(ctx(2)).find(person(2))
      trusted.update_node(hidden.ref, attrs: { classification: 3 })
      missing = ModelSpec::Person.in(ctx(2)).find(person(2))
      trusted.delete_node(missing.ref)

      errors = [hidden, missing].map do |record|
        record.name = "X"
        record.save
      rescue Pglpg::WriteRejected => e
        [e.class, e.message]
      end
      expect(errors.uniq).to eq([[Pglpg::WriteRejected, "write rejected"]])
    end

    it "preserves the properties of an unregistered subtype" do
      ref = trusted.insert_node(:Employee, properties: { uid: "E-1", name: "Eve", salary: BigDecimal("10.5") },
                                           attrs: { classification: 1 })
      eve = people.find(ref)
      eve.name = "Eva"
      eve.save!
      expect(stored(ref).properties).to include(name: "Eva", salary: BigDecimal("10.5"))
      expect(eve.reload.extra_properties).to eq(salary: BigDecimal("10.5"))
    end
  end

  describe "the trusted writer hand-off" do
    it "accepts only the record's own context's writer" do
      ann = people.find(person(1))
      ann.name = "Anne"

      expect { ann.save(writer: ctx.trusted_writer) }.to raise_error(ArgumentError, /another context/)
      expect { ann.save(writer: c) }.to raise_error(ArgumentError, /Pglpg::Writer/)
      expect(ann.changed?).to be(true)
      expect(ann.save(writer: c.trusted_writer)).to be(true)
    end
  end

  describe "destroying nodes" do
    it "needs the trusted writer" do
      ann = people.find(person(1))
      expect { ann.destroy }.to raise_error(Pglpg::NotTrusted)
      expect(ann).to be_persisted

      expect(ann.destroy(writer: c.trusted_writer)).to be(true)
      expect(ann).to be_destroyed
      expect(ann).not_to be_persisted
      expect { people.find(ann.ref) }.to raise_error(Pglpg::Model::RecordNotFound)
      expect { ann.save }.to raise_error(ArgumentError, /destroyed/)
      expect { ann.reload }.to raise_error(Pglpg::Model::RecordNotFound)
    end

    it "only destroys persisted records" do
      expect { people.new.destroy }.to raise_error(ArgumentError, /persisted/)
    end
  end

  describe "edges" do
    let(:ann) { people.find(person(1)) }
    let(:bob) { people.find(person(1)) }

    it "creates an edge between node models or refs" do
      k = ModelSpec::Knows.in(c).create!(source: ann, target: bob.ref, weight: 0.5, classification: 1)
      expect([k.source, k.target, k.weight]).to eq([ann.ref, bob.ref, 0.5])
      expect(stored(k.ref)).to have_attributes(source: ann.ref, target: bob.ref)
    end

    it "requires endpoints and required properties" do
      r = ModelSpec::Reviewed.in(c).new(classification: 1)
      expect(r).not_to be_valid
      expect(r.errors.to_hash).to eq(score: ["can't be blank"], source: ["can't be blank"], target: ["can't be blank"])
    end

    it "writes pair-unique types only through the trusted writer" do
      works = ModelSpec::WorksOn.in(c)
      apollo = project(1)
      expect { works.create(source: ann, target: apollo, classification: 1) }.to raise_error(ArgumentError, /unique per pair/)
      w = works.create!(source: ann, target: apollo, role: "lead", classification: 1, writer: c.trusted_writer)
      expect(w).to be_persisted
    end

    it "takes the canonical order of a symmetric edge" do
      a = ann.ref
      b = bob.ref
      f = ModelSpec::Friend.in(c).create!(source: b, target: a, classification: 1, writer: c.trusted_writer)
      expect([f.source, f.target]).to eq([a, b])
      expect(f.reload.source).to eq(a)
    end

    it "updates and destroys edges, and keeps endpoints fixed" do
      k = ModelSpec::Knows.in(c).create!(source: ann, target: bob, classification: 1)
      k.weight = 2.0
      k.save!
      expect(stored(k.ref)[:weight]).to eq(2.0)
      expect { k.source = bob }.to raise_error(ArgumentError, /can't change/)

      expect(k.destroy).to be(true)
      expect(stored(k.ref)).to be_nil
    end

    it "rejects endpoints of another graph or kind" do
      edge = trusted.insert_edge(:KNOWS, from: ann.ref, to: bob.ref, attrs: { classification: 1 })
      expect { ModelSpec::Knows.in(c).new(source: edge) }.to raise_error(Pglpg::InvalidRef)
      expect { ModelSpec::Knows.in(c).new(source: people.new) }.to raise_error(ArgumentError, /not stored/)
    end
  end

  describe "reload" do
    it "replaces attributes and the dirty baseline" do
      ann = people.find(person(1, name: "Ann"))
      trusted.update_node(ann.ref, properties: { name: "Anne" })
      ann.rank = 3

      ann.reload
      expect([ann.name, ann.rank, ann.changed?]).to eq(["Anne", nil, false])
    end

    it "raises for a hidden or missing element and leaves the record unchanged" do
      ann = ModelSpec::Person.in(ctx(2)).find(person(2, name: "Ann"))
      ann.name = "Anne"
      trusted.update_node(ann.ref, attrs: { classification: 3 })

      expect { ann.reload }.to raise_error(Pglpg::Model::RecordNotFound)
      expect([ann.name, ann.changes]).to eq(["Anne", { "name" => %w[Ann Anne] }])
      expect(ann).to be_persisted
    end

    it "fails closed after a rolled-back insert" do
      ann = people.new(name: "Ann", classification: 1)
      ActiveRecord::Base.transaction(requires_new: true) do
        ann.save!
        raise ActiveRecord::Rollback
      end

      expect { ann.reload }.to raise_error(Pglpg::Model::RecordNotFound)
      ann.name = "Anne"
      expect { ann.save }.to raise_error(Pglpg::WriteRejected)
      expect(people.count).to eq(0)
    end

    it "needs a saved record" do
      expect { people.new.reload }.to raise_error(Pglpg::Model::RecordNotFound)
    end
  end
end
