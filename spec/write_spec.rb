# frozen_string_literal: true

RSpec.describe "writes" do
  let(:conn) { ActiveRecord::Base.connection }

  describe "insert_node" do
    it "generates the key, derives labels and returns a Ref" do
      ref = ctx.insert_node(:Employee, properties: { name: "Ann", salary: BigDecimal("10.5") }, attrs: { classification: 2 })
      expect(ref).to be_a(Pglpg::Ref).and(have_attributes(graph: :spec_kg, kind: :node))
      node = ctx.find(ref)
      expect(node.key_label).to eq(:Employee)
      expect(node.labels).to eq(%i[Agent Employee Person])
      expect(node[:uid]).to match(/\A\h{8}-\h{4}-/)
      expect(node[:salary]).to eq(BigDecimal("10.5"))
      expect(node.attrs).to eq(classification: 2)
    end

    it "uses the key's generator" do
      ref = ctx.insert_node(:Location, attrs: { classification: 1 })
      expect(ctx.find(ref)[:uid]).to start_with("LOC-")
    end

    it "refuses caller-chosen keys before any SQL runs" do
      expect { ctx.insert_node(:Person, properties: { uid: "mine" }, attrs: { classification: 1 }) }
        .to raise_error(ArgumentError, /key/)
    end

    it "validates properties, columns and abstract types" do
      expect { ctx.insert_node(:Agent, attrs: { classification: 1 }) }.to raise_error(Pglpg::ValidationError, /abstract/)
      expect { ctx.insert_node(:Person, properties: { nope: 1 }, attrs: { classification: 1 }) }
        .to raise_error(Pglpg::ValidationError, /nope/)
      expect { ctx.insert_node(:Project, attrs: { classification: 1 }) }.to raise_error(Pglpg::ValidationError, /title/)
      expect { ctx.insert_node(:Person) }.to raise_error(Pglpg::ValidationError, /classification is required/)
      expect { ctx.insert_node(:Person, attrs: { classification: 1, other: 1 }) }.to raise_error(Pglpg::ValidationError)
    end

    it "asks the write policy, which sees the requested new state" do
      expect { ctx(2).insert_node(:Person, attrs: { classification: 3 }) }.to raise_error(Pglpg::WriteRejected)
      expect(ctx(3).insert_node(:Person, attrs: { classification: 3 })).to be_a(Pglpg::Ref)
    end
  end

  describe "update_node" do
    it "merges properties, removes nil ones and sets columns" do
      ref = person(1, name: "Ann", rank: 1)
      ctx.update_node(ref, properties: { rank: 2, name: nil }, attrs: { classification: 2 })
      node = ctx.find(ref)
      expect(node.properties.keys).to contain_exactly(:uid, :rank)
      expect(node[:rank]).to eq(2)
      expect(node.attrs[:classification]).to eq(2)
    end

    it "rejects a hidden node exactly like a missing one" do
      hidden = person(4)
      missing = Kg.ref(:node, hidden.id + 1000)
      errors = [hidden, missing].map do |ref|
        ctx(2).update_node(ref, properties: { name: "x" })
      rescue Pglpg::Error => e
        [e.class, e.message]
      end
      expect(errors.uniq).to eq([[Pglpg::WriteRejected, "write rejected"]])
      expect(ctx.find(hidden)[:name]).to be_nil
    end

    it "keeps keys immutable and required properties present" do
      ref = project(1)
      expect { ctx.update_node(ref, properties: { uid: "x" }) }.to raise_error(ArgumentError, /keys/)
      expect { ctx.update_node(ref, properties: { title: nil }) }.to raise_error(Pglpg::ValidationError)
      expect { ctx.update_node(ref, attrs: { classification: nil }) }.to raise_error(Pglpg::ValidationError)
    end

    it "re-checks the stored row inside the statement" do
      ref = person(2)
      # A concurrent reclassification between the preflight read and the update:
      # the policy's condition on the stored row still holds the line.
      stale = ctx(2).find(ref)
      context = SimpleDelegator.new(ctx(2))
      context.define_singleton_method(:find) { |_ref| stale }
      writer = Pglpg::Writer.new(context, trusted: false)
      conn.execute("UPDATE #{Kg.nodes_table} SET classification = 4 WHERE id = #{ref.id}")
      expect { writer.update_node(ref, properties: { name: "x" }) }.to raise_error(Pglpg::WriteRejected)
    end

    it "rejects refs of other graphs and kinds before any SQL runs" do
      expect { ctx.update_node(Pglpg::Ref.new(graph: :other, kind: :node, id: 1)) }.to raise_error(Pglpg::InvalidRef)
      expect { ctx.update_node(Kg.ref(:edge, 1)) }.to raise_error(Pglpg::InvalidRef)
    end
  end

  describe "a policy condition on the stored row" do
    it "limits allowed transitions" do
      no_downgrade = Module.new do
        def self.authorize?(_request) = true

        # Classification may only go up.
        def self.existing(table, request)
          level = request.attrs[:classification]
          level ? table[:classification].lteq(level) : nil
        end
      end
      Pglpg.configure { _1.write_policy = no_downgrade }
      ref = person(3)
      expect { ctx.update_node(ref, attrs: { classification: 2 }) }.to raise_error(Pglpg::WriteRejected)
      ctx.update_node(ref, attrs: { classification: 4 })
      expect(ctx.find(ref).attrs[:classification]).to eq(4)
    end
  end

  describe "insert_edge" do
    it "connects visible endpoints of the declared types" do
      a = person(1)
      b = person(1)
      ref = ctx(1).insert_edge(:KNOWS, from: a, to: b, properties: { weight: 0.5 }, attrs: { classification: 1 })
      edge = ctx(1).find(ref)
      expect([edge.type, edge.source, edge.target, edge[:weight]]).to eq([:KNOWS, a, b, 0.5])
    end

    it "matches endpoint types by label, so subtypes qualify" do
      e = ctx.insert_node(:Employee, attrs: { classification: 1 })
      b = person(1)
      expect(ctx.insert_edge(:KNOWS, from: e, to: b, attrs: { classification: 1 })).to be_a(Pglpg::Ref)
    end

    it "rejects hidden endpoints exactly like missing ones and wrong endpoint types" do
      a = person(1)
      hidden = person(4)
      j = project(1)
      cases = [
        -> { ctx(2).insert_edge(:KNOWS, from: a, to: hidden, attrs: { classification: 1 }) },
        -> { ctx(2).insert_edge(:KNOWS, from: a, to: Kg.ref(:node, hidden.id + 1000), attrs: { classification: 1 }) },
        -> { ctx(2).insert_edge(:KNOWS, from: a, to: j, attrs: { classification: 1 }) }
      ]
      cases.each { expect(&_1).to raise_error(Pglpg::WriteRejected, "write rejected") }
    end

    it "sends pair-unique edge types through the trusted writer" do
      expect { ctx.insert_edge(:WORKS_ON, from: person, to: project, attrs: { classification: 1 }) }
        .to raise_error(ArgumentError, /trusted writer/)
    end

    it "rejects endpoint refs of another graph" do
      foreign = Pglpg::Ref.new(graph: :other, kind: :node, id: 1)
      expect { ctx.insert_edge(:KNOWS, from: person, to: foreign, attrs: { classification: 1 }) }
        .to raise_error(Pglpg::InvalidRef)
    end
  end

  describe "update_edge and delete_edge" do
    it "require the edge and both endpoints to be visible" do
      a = person(1)
      b = person(3)
      ref = ctx.insert_edge(:KNOWS, from: a, to: b, attrs: { classification: 1 })
      expect { ctx(2).update_edge(ref, properties: { weight: 1.0 }) }.to raise_error(Pglpg::WriteRejected)
      expect { ctx(2).delete_edge(ref) }.to raise_error(Pglpg::WriteRejected)
      ctx(3).update_edge(ref, properties: { weight: 1.0 })
      expect(ctx(3).find(ref)[:weight]).to eq(1.0)
      expect(ctx(3).delete_edge(ref)).to be(true)
      expect(ctx.find(ref)).to be_nil
    end
  end

  describe "the trusted writer" do
    it "is granted only by the application" do
      expect { ctx(2).trusted_writer }.to raise_error(Pglpg::NotTrusted)
      Pglpg.configure { _1.trusted_writer_allowed = nil }
      expect { ctx(4).trusted_writer }.to raise_error(Pglpg::NotTrusted)
      expect { ctx.upsert_node(:Person, key: { uid: "x" }) }.to raise_error(NoMethodError)
    end

    it "does not bypass the write policy" do
      expect { trusted(3).insert_node(:Person, properties: { uid: "x" }, attrs: { classification: 4 }) }
        .to raise_error(Pglpg::WriteRejected)
    end

    it "upserts nodes by key, merging properties" do
      ref = trusted.upsert_node(:Person, key: { uid: "PER-1" }, properties: { name: "Ann", rank: 1 },
                                         attrs: { classification: 1 })
      again = trusted.upsert_node(:Person, key: { uid: "PER-1" }, properties: { rank: 2 }, attrs: { classification: 2 })
      expect(again).to eq(ref)
      node = ctx.find(ref)
      expect([node[:name], node[:rank], node.attrs[:classification]]).to eq(["Ann", 2, 2])
    end

    it "rejects an upsert that hits a hidden row without revealing it" do
      hidden = trusted(4).upsert_node(:Person, key: { uid: "PER-H" }, attrs: { classification: 4 })
      expect { trusted(3).upsert_node(:Person, key: { uid: "PER-H" }, properties: { name: "x" }, attrs: { classification: 3 }) }
        .to raise_error(Pglpg::WriteRejected, "write rejected")
      expect(ctx.find(hidden)[:name]).to be_nil
    end

    it "does not let an upsert turn a node into another type" do
      trusted.upsert_node(:Person, key: { uid: "PER-T" }, attrs: { classification: 1 })
      expect { trusted.upsert_node(:Employee, key: { uid: "PER-T" }, attrs: { classification: 1 }) }
        .to raise_error(Pglpg::WriteRejected)
    end

    it "checks upsert arguments" do
      expect { trusted.upsert_node(:Note, key: { uid: "x" }) }.to raise_error(ArgumentError, /no key/)
      expect { trusted.upsert_node(:Person, key: { name: "x" }) }.to raise_error(ArgumentError, /uid/)
      expect { trusted.upsert_node(:Person, key: { uid: "x" }, properties: { uid: "y" }) }.to raise_error(ArgumentError)
      expect { trusted.upsert_edge(:KNOWS, from: person, to: person) }.to raise_error(ArgumentError, /not unique/)
    end

    it "upserts pair-unique edges" do
      a = person(1)
      j = project(1)
      ref = trusted.upsert_edge(:WORKS_ON, from: a, to: j, properties: { role: "dev" }, attrs: { classification: 1 })
      again = trusted.upsert_edge(:WORKS_ON, from: a, to: j, properties: { role: "lead" }, attrs: { classification: 1 })
      expect(again).to eq(ref)
      expect(ctx.find(ref)[:role]).to eq("lead")
      expect { trusted.insert_edge(:WORKS_ON, from: a, to: j, attrs: { classification: 1 }) }
        .to raise_error(Pglpg::WriteRejected)
    end

    it "rejects an edge upsert that hits a hidden edge" do
      a = person(1)
      j = project(1)
      trusted(4).upsert_edge(:WORKS_ON, from: a, to: j, attrs: { classification: 4 })
      expect { trusted(3).upsert_edge(:WORKS_ON, from: a, to: j, attrs: { classification: 3 }) }
        .to raise_error(Pglpg::WriteRejected, "write rejected")
    end

    it "deletes nodes without edges" do
      a = person(1)
      b = person(1)
      ctx.insert_edge(:KNOWS, from: a, to: b, attrs: { classification: 1 })
      expect { trusted.delete_node(a) }.to raise_error(Pglpg::WriteRejected)
      c = person(1)
      expect(trusted.delete_node(c)).to be(true)
      expect(ctx.find(c)).to be_nil
    end
  end

  it "never aborts the caller's transaction" do
    ActiveRecord::Base.transaction(requires_new: true) do
      hidden = person(4)
      expect { ctx(1).update_node(hidden, properties: { name: "x" }) }.to raise_error(Pglpg::WriteRejected)
      expect { trusted.insert_node(:Person, properties: { uid: ctx.find(hidden)[:uid] }, attrs: { classification: 1 }) }
        .to raise_error(Pglpg::WriteRejected)
      expect(person(1)).to be_a(Pglpg::Ref)
    end
  end

  it "fails closed when no policy is configured" do
    Pglpg.reset_configuration!
    expect { ctx.insert_node(:Person, attrs: { classification: 1 }) }.to raise_error(Pglpg::ConfigurationError)
    expect { ctx.match.node(:p).to_a }.to raise_error(Pglpg::ConfigurationError)
  end
end
