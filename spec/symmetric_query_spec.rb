# frozen_string_literal: true

# ADR-0008: symmetric edge types match like GQL undirected edges.
RSpec.describe "symmetric edges in patterns" do
  # Created in this order, so bob.id < ann.id < cy.id, as in the ADR's examples.
  let!(:bob) { person(1, name: "Bob") }
  let!(:ann) { person(1, name: "Ann") }
  let!(:cy) { person(1, name: "Cy") }
  let!(:ann_bob) { trusted.insert_edge(:FRIEND, from: ann, to: bob, attrs: { classification: 1 }) }
  let!(:ann_cy) { trusted.insert_edge(:FRIEND, from: ann, to: cy, attrs: { classification: 1 }) }

  def pairs(rows, a = :a, b = :b) = rows.map { [_1[a][:name], _1[b][:name]] }

  it "stores the pair in canonical orientation" do
    edge = ctx.find(ann_bob)
    expect([edge.source, edge.target]).to eq([bob, ann])
  end

  it "follows an edge from either stored end" do
    expect(pairs(ctx.match.node(:a, ref: ann).both(:FRIEND, :b, :Person).order(b: :name).to_a))
      .to eq([%w[Ann Bob], %w[Ann Cy]])
    expect(pairs(ctx.match.node(:a, ref: bob).both(:FRIEND, :b).to_a)).to eq([%w[Bob Ann]])
    # A condition on the start node finds edges whichever end it is stored at.
    expect(pairs(ctx.match.node(:a, :Person, name: "Ann").both(:FRIEND, :b, :Person).order(b: :name).to_a))
      .to eq([%w[Ann Bob], %w[Ann Cy]])
  end

  it "binds each edge once per orientation, and lists it once with distinct" do
    q = ctx.match.node(:a, :Person).both(:FRIEND, :b, :Person, edge: :k)
    expect(pairs(q.order(a: :name, b: :name).to_a)).to eq([%w[Ann Bob], %w[Ann Cy], %w[Bob Ann], %w[Cy Ann]])
    expect(q.count).to eq(4)
    expect(q.return(:k).distinct.count).to eq(2)
    expect(q.return(:k).distinct.to_a.map { _1[:k].ref }).to contain_exactly(ann_bob, ann_cy)
  end

  it "binds different edges in one pattern" do
    rows = ctx.match.node(:a, ref: bob).both(:FRIEND, :b).both(:FRIEND, :c).to_a
    expect(rows.map { [_1[:a][:name], _1[:b][:name], _1[:c][:name]] }).to eq([%w[Bob Ann Cy]])
  end

  it "closes cycles through a bound variable" do
    trusted.insert_edge(:FRIEND, from: bob, to: cy, attrs: { classification: 1 })
    rows = ctx.match.node(:a, ref: ann).both(:FRIEND, :b).both(:FRIEND, :c).both(:FRIEND, :a).to_a
    expect(rows.map { [_1[:b][:name], _1[:c][:name]] }).to contain_exactly(%w[Bob Cy], %w[Cy Bob])
  end

  it "filters and returns the edge" do
    trusted.upsert_edge(:FRIEND, from: bob, to: ann, properties: { since: Date.new(2020, 1, 1) },
                                 attrs: { classification: 1 })
    rows = ctx.match.node(:a, ref: ann).both(:FRIEND, :b, edge: :k).where(k: { since: Pglpg.gte(Date.new(2019, 1, 1)) }).to_a
    expect(rows.map { [_1[:b][:name], _1[:k].ref] }).to eq([["Bob", ann_bob]])
  end

  it "binds a self-loop once" do
    trusted.insert_edge(:SAME_AS, from: ann, to: ann, attrs: { classification: 1 })
    expect(ctx.match.node(:a, ref: ann).both(:SAME_AS, :b).to_a.map { _1[:b].ref }).to eq([ann])
    expect(ctx.match.node(:a, :Person).both(:SAME_AS, :b, edge: :s).count).to eq(1)
  end

  it "keeps direction and symmetry apart" do
    expect { ctx.match.node(:a, ref: ann).out(:FRIEND, :b) }.to raise_error(ArgumentError, /FRIEND is symmetric; use both/)
    expect { ctx.match.node(:a, ref: ann).in(:FRIEND, :b) }.to raise_error(ArgumentError, /symmetric/)
    expect { ctx.match.node(:a, ref: ann).both(:KNOWS, :b) }.to raise_error(ArgumentError, /KNOWS is directed/)
  end

  it "applies visibility to the edge and the far node, from either end" do
    hidden = person(3, name: "Hal")
    trusted.insert_edge(:MET, from: hidden, to: ann, attrs: { classification: 1 })
    trusted.insert_edge(:MET, from: bob, to: ann, attrs: { classification: 3 })
    expect(ctx(2).match.node(:a, ref: ann).both(:MET, :b).to_a).to be_empty
    expect(ctx(3).match.node(:a, ref: ann).both(:MET, :b).count).to eq(2)
  end

  # The same visible graph, created in opposite id orders, gives the same
  # results: no match depends on which node has the smaller id.
  it "does not depend on id order" do
    results = [%w[Dee Eve Fay], %w[Fay Eve Dee]].map do |order|
      refs = order.to_h { [_1, person(1, name: _1)] }
      ctx.insert_edge(:MET, from: refs["Dee"], to: refs["Eve"], attrs: { classification: 1 })
      ctx.insert_edge(:MET, from: refs["Fay"], to: refs["Eve"], attrs: { classification: 1 })
      starts = ->(name) { pairs(ctx.match.node(:a, :Person, name:).both(:MET, :b, :Person).order(b: :name).to_a) }
      observed = %w[Dee Eve Fay].to_h { [_1, starts.(_1)] }
      ctx.match.node(:a, ref: refs["Eve"]).both(:MET, :b, edge: :k).to_a.each { ctx.delete_edge(_1[:k].ref) }
      observed
    end
    expect(results[0]).to eq(results[1])
    expect(results[0]["Eve"]).to eq([%w[Eve Dee], %w[Eve Fay]])
  end
end
