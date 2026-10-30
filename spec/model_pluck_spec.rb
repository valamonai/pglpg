# frozen_string_literal: true

RSpec.describe "Pglpg::Model pluck" do
  let(:people) { ModelSpec::Person.in(ctx) }

  def review(from, to, score, level = 1)
    trusted.insert_edge(:REVIEWED, from:, to:, properties: { score: }, attrs: { classification: level })
  end

  it "projects attributes and identity of a relation, in its order" do
    a = person(1, name: "Ann", rank: 2)
    b = person(1, name: "Bob", rank: 1)

    expect(people.order(:name).pluck(:name)).to eq(%w[Ann Bob])
    expect(people.order(:rank).pluck(:name, :rank, :classification)).to eq([["Bob", 1, 1], ["Ann", 2, 1]])
    expect(people.order(:name).pluck(:id, :ref)).to eq([[a.id, a], [b.id, b]])
    expect(people.order(:name).limit(1).pluck(:name)).to eq(%w[Ann])
    expect(people.where(name: "Zed").pluck(:name)).to eq([])
  end

  it "keeps equal values of different targets, and one value per deduplicated target" do
    ann = people.find(person(1))
    r1 = project(1, title: "Review")
    r2 = project(1, title: "Review")
    review(ann.ref, r1, 1)
    review(ann.ref, r1, 2)
    review(ann.ref, r2, 3)

    expect(ann.reviewed_projects.pluck(:title)).to eq(%w[Review Review])
    expect(ann.reviewed_projects.pluck(:id)).to eq([r1.id, r2.id])
  end

  it "projects one entry per pair on a binding query" do
    ann = people.find(person(1))
    apollo = project(1, title: "Apollo")
    gemini = project(1, title: "Gemini")
    review(ann.ref, apollo, 5)
    review(ann.ref, apollo, 1)
    review(ann.ref, gemini, 3)

    pairs = ann.reviewed_projects.with_rel.order(:title).rel_order(:score)
    expect(pairs.pluck(:title)).to eq(%w[Apollo Apollo Gemini])
    expect(pairs.pluck(:title, rel: :score)).to eq([["Apollo", 1], ["Apollo", 5], ["Gemini", 3]])
    expect(pairs.pluck(rel: %i[score classification])).to eq([[1, 1], [5, 1], [3, 1]])
    expect(pairs.pluck(rel: :score)).to eq([1, 5, 3])
  end

  it "applies the visibility policy" do
    person(1, name: "Low")
    person(3, name: "High")
    expect(ModelSpec::Person.in(ctx(2)).pluck(:name)).to eq(%w[Low])
  end

  it "keeps the row budget" do
    Pglpg.configuration.max_rows = 2
    3.times { person(1) }
    expect { people.pluck(:name) }.to raise_error(Pglpg::TooManyRows)
    expect(people.limit(2).pluck(:name).size).to eq(2)
  end

  it "rejects unknown names before running a query" do
    expect { people.pluck(:salary) }.to raise_error(ArgumentError, /has no attribute :salary to pluck/)
    expect { people.pluck }.to raise_error(ArgumentError, /at least one name/)
    ann = people.find(person(1))
    expect { ann.reviewed_projects.with_rel.pluck(:title, rel: :role) }.to raise_error(ArgumentError, /has no attribute :role/)
    expect { ann.reviewed_projects.with_rel.pluck }.to raise_error(ArgumentError, /at least one name/)
  end
end
