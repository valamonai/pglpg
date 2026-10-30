# frozen_string_literal: true

RSpec.describe "model eager loading" do
  let(:people) { ModelSpec::Person.in(ctx(2)) }

  def link(type, from, to, level = 1, **properties)
    trusted.insert_edge(type, from:, to:, properties:, attrs: { classification: level })
  end

  it "batches, deduplicates and caches visible targets, including empty associations" do
    a = person(1, name: "A")
    b = person(1, name: "B")
    target = project(1, title: "Visible")
    hidden = project(3, title: "Hidden")
    2.times { link(:REVIEWED, a, target, 1, score: 1) }
    link(:REVIEWED, b, target, 1, score: 2)
    link(:REVIEWED, a, hidden, 1, score: 3)
    link(:REVIEWED, a, project(1, title: "Hidden edge"), 3, score: 4)
    counts = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      counts << payload[:sql] if payload[:sql].match?(/SELECT DISTINCT.*spec_kg_nodes/i)
    end
    begin
      records = people.with_associations(:reviewed_projects).to_a
      expect(counts.size).to eq(1)
      expect(records.map { |x| x.reviewed_projects.pluck(:title) }).to eq([["Visible"], ["Visible"]])
      expect(records.first.reviewed_projects.to_a).to be_frozen
      expect(records.first.reviewed_projects.first).to equal(records.last.reviewed_projects.first)
      expect(counts.size).to eq(1)
      expect(records.first.reviewed_projects.where(title: "Visible").count).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  it "handles nested, incoming and symmetric paths and empty batches" do
    a = person(1, name: "A")
    b = person(1, name: "B")
    link(:KNOWS, a, b)
    link(:FRIEND, a, b)
    loaded = people.with_associations(:known_by, friends: :friends).to_a
    loaded.each do |owner|
      lazy = people.find(owner.ref)
      expect(owner.known_by.map(&:ref)).to eq(lazy.known_by.map(&:ref))
      expect(owner.friends.map(&:ref)).to eq(lazy.friends.map(&:ref))
      owner.friends.each { |friend| expect(friend.friends.map(&:ref)).to eq(people.find(friend.ref).friends.map(&:ref)) }
    end
    expect(people.where(name: "absent").with_associations(friends: :friends).to_a).to eq([])
  end

  it "validates trees before querying and rejects binding relations" do
    expect { people.with_associations(friends: :unknown) }.to raise_error(ArgumentError)
    cyclic = {}; cyclic[:friends] = cyclic
    expect { people.with_associations(cyclic) }.to raise_error(ArgumentError, /cyclic/)
    owner = people.find(person(1))
    expect { owner.friends.with_rel.with_associations(:friends) }.to raise_error(ArgumentError)
  end

  it "enforces the pair budget after deduplication" do
    a = person(1); b = person(1); t = project(1)
    2.times { link(:REVIEWED, a, t, 1, score: 1) }
    link(:REVIEWED, b, t, 1, score: 1)
    old = Pglpg.configuration.max_rows
    begin
      Pglpg.configuration.max_rows = 2
      expect(people.with_associations(:reviewed_projects).to_a.size).to eq(2)
      link(:REVIEWED, b, project(1), 1, score: 1)
      expect { people.with_associations(:reviewed_projects).to_a }.to raise_error(Pglpg::TooManyRows)
    ensure
      Pglpg.configuration.max_rows = old
    end
  end
  it "clears caches after reload and save, and bypasses them on modified relations" do
    a = person(1, name: "A")
    t = project(1, title: "First")
    link(:WORKS_ON, a, t)
    owner = people.with_associations(:projects).first
    later = project(1, title: "Later")
    link(:WORKS_ON, a, later)
    expect(owner.projects.pluck(:title)).to eq(["First"])
    expect(owner.projects.where(title: "Later").pluck(:title)).to eq(["Later"])
    owner.reload
    expect(owner.projects.pluck(:title)).to eq(["First", "Later"])
    owner = people.with_associations(:projects).first
    third = project(1, title: "Third")
    link(:WORKS_ON, a, third)
    expect(owner.save).to be(true)
    expect(owner.projects.pluck(:title)).to eq(["First", "Later", "Third"])
  end

  it "merges trees and runs at most one statement per tree node" do
    a = person(1, name: "A"); b = person(1, name: "B")
    link(:KNOWS, a, b)
    counts = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      sql = args.last[:sql]
      counts << sql if sql.match?(/SELECT .*spec_kg_nodes/i)
    end
    begin
      records = people.with_associations(:known).with_associations(known: :known_by).to_a
      expect(counts.size).to eq(3)
      records.each { |owner| owner.known.each { |target| target.known_by.to_a } }
      expect(counts.size).to eq(3)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

end
