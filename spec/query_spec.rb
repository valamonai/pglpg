# frozen_string_literal: true

RSpec.describe Pglpg::Query do
  let!(:ann) { person(1, name: "Ann", rank: 1, born: Date.new(1990, 5, 1), status: "active") }
  let!(:bob) { person(1, name: "Bob", rank: 2, born: Date.new(1985, 1, 1), status: "retired") }
  let!(:cid) { person(1, name: "Cid", rank: 3) }
  let!(:apollo) { project(1, title: "Apollo", headcount: 3, started_at: Time.utc(2020, 1, 1)) }
  let!(:gemini) { project(1, title: "Gemini", headcount: 0) }
  let!(:houston) { ctx.insert_node(:Location, attrs: { classification: 1 }) }
  let!(:works) do
    {
      ann: trusted.upsert_edge(:WORKS_ON, from: ann, to: apollo, properties: { role: "lead" }, attrs: { classification: 1 }),
      bob: trusted.upsert_edge(:WORKS_ON, from: bob, to: apollo, properties: { role: "dev" }, attrs: { classification: 1 }),
      cid: trusted.upsert_edge(:WORKS_ON, from: cid, to: gemini, properties: { role: "lead" }, attrs: { classification: 1 })
    }
  end

  before do
    ctx.insert_edge(:BASED_AT, from: apollo, to: houston, attrs: { classification: 1 })
    ctx.insert_edge(:KNOWS, from: ann, to: bob, attrs: { classification: 1 })
    ctx.insert_edge(:KNOWS, from: bob, to: cid, attrs: { classification: 1 })
  end

  def names(rows, var = :p) = rows.map { _1[var][:name] }

  it "matches a start node by label" do
    expect(names(ctx.match.node(:p, :Person).order(p: :name).to_a)).to eq(%w[Ann Bob Cid])
  end

  it "follows outgoing and incoming edges, with edge variables" do
    rows = ctx.match.node(:p, :Person).out(:WORKS_ON, :j, :Project, edge: :w).out(:BASED_AT, :l, :Location).to_a
    expect(rows.map { [_1[:p][:name], _1[:w][:role], _1[:j][:title], _1[:l].ref] })
      .to eq([["Ann", "lead", "Apollo", houston], ["Bob", "dev", "Apollo", houston]])

    rows = ctx.match.node(:l, :Location).in(:BASED_AT, :j, :Project).in(:WORKS_ON, :p, :Person).to_a
    expect(names(rows)).to eq(%w[Ann Bob])
  end

  it "branches from an earlier variable and closes cycles" do
    rows = ctx.match.node(:j, :Project, title: "Apollo").in(:WORKS_ON, :p, :Person).out(:BASED_AT, :l, from: :j).to_a
    expect(names(rows)).to eq(%w[Ann Bob])

    # Coworkers on the same project who know each other.
    rows = ctx.match.node(:a, :Person).out(:WORKS_ON, :j, :Project).in(:WORKS_ON, :b, :Person).out(:KNOWS, :a, from: :b).to_a
    expect(rows.map { [_1[:a][:name], _1[:b][:name]] }).to eq([%w[Bob Ann]])
  end

  it "uses different edges for edges of the same type" do
    rows = ctx.match.node(:p, :Person, name: "Ann").out(:WORKS_ON, :j, :Project).in(:WORKS_ON, :q, :Person).to_a
    expect(names(rows, :q)).to eq(%w[Bob])
  end

  it "starts from a Ref" do
    expect(ctx.match.node(:p, ref: bob).out(:KNOWS, :q).to_a.map { _1[:q].ref }).to eq([cid])
  end

  it "filters by structured conditions" do
    q = ctx.match.node(:p, :Person)
    expect(names(q.where(p: { rank: Pglpg.gt(1) }).order(p: :name).to_a)).to eq(%w[Bob Cid])
    expect(names(q.where(p: { rank: Pglpg.lte(2), name: Pglpg.ne("Ann") }).to_a)).to eq(%w[Bob])
    expect(names(q.where(p: { name: %w[Ann Cid] }).order(p: :name).to_a)).to eq(%w[Ann Cid])
    expect(names(q.where(p: { rank: Pglpg.in([2, 3]) }).order(p: :name).to_a)).to eq(%w[Bob Cid])
    expect(names(q.where(p: { born: Pglpg.lt(Date.new(1989, 1, 1)) }).to_a)).to eq(%w[Bob])
    expect(names(q.where(p: { status: "retired" }).to_a)).to eq(%w[Bob])
    expect(names(q.where(p: { born: nil }).to_a)).to eq(%w[Cid])
    expect(ctx.match.node(:j, :Project).where(j: { started_at: Pglpg.gte(Time.utc(2019, 1, 1)) }).count).to eq(1)
    expect(ctx.match.node(:j, :Project, headcount: 0).first[:j][:title]).to eq("Gemini")
    rows = ctx.match.node(:p, :Person).out(:WORKS_ON, :j, :Project, edge: :w).where(w: { role: "lead" }).to_a
    expect(names(rows)).to eq(%w[Ann Cid])
  end

  it "matches subtypes through the parent label" do
    ctx.insert_node(:Employee, properties: { name: "Eve" }, attrs: { classification: 1 })
    expect(names(ctx.match.node(:p, :Person).order(p: :name).to_a)).to eq(%w[Ann Bob Cid Eve])
    expect(names(ctx.match.node(:p, :Employee).to_a)).to eq(%w[Eve])
    expect(ctx.match.node(:p, :Agent).count).to eq(4)
  end

  it "rejects undeclared or unfilterable properties and unknown names" do
    q = ctx.match.node(:p, :Person)
    expect { q.where(p: { nope: 1 }) }.to raise_error(ArgumentError, /nope/)
    expect { q.where(p: { tags: ["a"] }) }.to raise_error(ArgumentError, /list/)
    expect { q.where(p: { rank: "2" }) }.to raise_error(Pglpg::ValidationError)
    expect { ctx.match.node(:p).where(p: { name: "x" }) }.to raise_error(ArgumentError, /label/)
    expect { q.out(:NOPE, :x) }.to raise_error(ArgumentError, /unknown edge type/)
    expect { ctx.match.node(:p, :Nope) }.to raise_error(ArgumentError, /unknown node type/)
    expect { q.node(:q) }.to raise_error(ArgumentError, /one start node/)
    expect { q.out(:KNOWS, :p, :Project) }.to raise_error(ArgumentError, /already bound/)
    expect { q.out(:KNOWS, :q, :Person, edge: :q) }.to raise_error(ArgumentError, /already bound/)
    expect { q.out(:KNOWS, :q, :Person, edge: :p) }.to raise_error(ArgumentError, /already bound/)
    expect { q.where(x: { name: "a" }) }.to raise_error(ArgumentError, /unknown variable/)
    expect { q.return(:x) }.to raise_error(ArgumentError)
    expect { q.where(p: { rank: 1..2 }) }.to raise_error(ArgumentError, /ranges/)
  end

  it "returns selected variables, distinct rows, counts and existence" do
    q = ctx.match.node(:p, :Person).out(:WORKS_ON, :j, :Project)
    expect(q.return(:j).to_a.map { _1.keys }).to all(eq([:j]))
    expect(q.return(:j).count).to eq(3)
    expect(q.return(:j).distinct.count).to eq(2)
    expect(q.return(:j).distinct.order(j: { title: :desc }).to_a.map { _1[:j][:title] }).to eq(%w[Gemini Apollo])
    expect { q.return(:j).distinct.order(p: :name).to_a }.to raise_error(ArgumentError, /distinct/)
    expect(q.exists?).to be(true)
    expect(q.where(j: { title: "Nope" }).exists?).to be(false)
  end

  it "orders deterministically and paginates" do
    q = ctx.match.node(:p, :Person).out(:WORKS_ON, :j, :Project).order(j: :title)
    all = q.to_a.map { [_1[:p][:name], _1[:j][:title]] }
    expect(all).to eq([%w[Ann Apollo], %w[Bob Apollo], %w[Cid Gemini]])
    expect(q.limit(2).offset(1).to_a.map { _1[:p][:name] }).to eq(%w[Bob Cid])
    expect(q.limit(2).offset(1).count).to eq(2)
    expect(q.offset(5).exists?).to be(false)
  end

  it "caps result sizes" do
    Pglpg.configure { _1.max_rows = 2 }
    expect { ctx.match.node(:p, :Person).to_a }.to raise_error(Pglpg::TooManyRows)
    expect(ctx.match.node(:p, :Person).limit(2).to_a.size).to eq(2)
    expect { ctx.match.node(:p, :Person).limit(3) }.to raise_error(ArgumentError, /max_rows/)
    expect(ctx.match.node(:p, :Person).count).to eq(3)
  end

  it "applies the statement timeout and restores the previous one" do
    Pglpg.configure { _1.statement_timeout = 1 }
    big = Kg.for(viewer: Viewer.new(4))
    conn = ActiveRecord::Base.connection
    slow = Module.new do
      def self.node(_table, _viewer) = Arel.sql("pg_sleep(0.05) IS NOT NULL")
      def self.edge(_table, _viewer) = Arel.sql("TRUE")
    end
    Pglpg.configure { _1.visibility = slow }
    expect { big.match.node(:p, :Person).to_a }.to raise_error(Pglpg::QueryTimeout)
    expect(conn.select_value("SHOW statement_timeout")).to eq("0")
  end

  it "finds nodes and edges by Ref and nodes by key" do
    expect(ctx.find(ann)[:name]).to eq("Ann")
    uid = ctx.find(ann)[:uid]
    expect(ctx.find_node(:Person, uid:).ref).to eq(ann)
    expect(ctx.find_node(:Agent, uid:).ref).to eq(ann)
    expect(ctx.find(works[:bob])).to have_attributes(type: :WORKS_ON, source: bob, target: apollo)
    expect { ctx.find_node(:Person, name: "Ann") }.to raise_error(ArgumentError)
    expect { ctx.find(Pglpg::Ref.new(graph: :other, kind: :node, id: 1)) }.to raise_error(Pglpg::InvalidRef)
  end

  it "binds every value as a parameter" do
    sql, binds = ctx.match.node(:p, :Person, name: "Robert'); DROP TABLE x; --").out(:KNOWS, :q).to_sql
    expect(sql).not_to include("Robert")
    expect(binds).to include(JSON.generate("name" => "Robert'); DROP TABLE x; --"))
  end

  it "explains the generated SQL" do
    plan = ctx.match.node(:p, ref: ann).out(:WORKS_ON, :j, :Project).explain(analyze: true, buffers: true)
    expect(plan.join("\n")).to include("Execution Time")
  end

  it "applies the statement timeout to EXPLAIN ANALYZE" do
    Pglpg.configure { _1.statement_timeout = 1 }
    slow = Module.new do
      def self.node(_table, _viewer) = Arel.sql("pg_sleep(0.05) IS NOT NULL")
      def self.edge(_table, _viewer) = Arel.sql("TRUE")
    end
    Pglpg.configure { _1.visibility = slow }
    expect { ctx.match.node(:p, :Person).explain(analyze: true) }.to raise_error(Pglpg::QueryTimeout)
  end

  it "builds immutable queries" do
    base = ctx.match.node(:p, :Person)
    base.where(p: { name: "Ann" })
    expect(base.count).to eq(3)
    expect(base).to be_frozen
  end
end
