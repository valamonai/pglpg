# frozen_string_literal: true

RSpec.describe "model eager loading" do
  let(:people) { ModelSpec::Person.in(ctx(2)) }

  def link(type, from, to, level = 1, **properties)
    trusted.insert_edge(type, from:, to:, properties:, attrs: { classification: level })
  end

  it "batches, deduplicates and caches visible targets, including empty associations" do
    a = person(1, name: "A")
    b = person(1, name: "B")
    person(1, name: "Empty")
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
      expect(records.map { |x| x.reviewed_projects.pluck(:title) }).to eq([["Visible"], ["Visible"], []])
      expect(records.first.reviewed_projects.to_a).to be_frozen
      expect(records.first.reviewed_projects.first).to equal(records[1].reviewed_projects.first)
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
      expect(counts.size).to eq(1 + 2)
      records.each { |owner| owner.known.each { |target| target.known_by.to_a } }
      expect(counts.size).to eq(1 + 2)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  it "rejects converting pending preloads into binding queries" do
    owner = people.find(person(1))
    expect { owner.known.with_associations(:known_by).with_rel }.to raise_error(ArgumentError, /pending preloads/)
  end

  it "deduplicates symmetric self-loops just as lazy reads do" do
    g = Pglpg::Graph.define(:eager_loop) do
      column :classification, :integer
      node :P
      edge :LINK, from: :P, to: :P, symmetric: true, allow_self_loops: true
    end
    g.storage.create!
    model = Class.new(Pglpg::Model::Node) do
      graph g, type: :P
      has_many :links, :both, edge: :LINK
    end
    context = g.for(viewer: Viewer.new(2))
    writer = context
    ref = writer.insert_node(:P, attrs: { classification: 1 })
    writer.insert_edge(:LINK, from: ref, to: ref, attrs: { classification: 1 })
    owner = model.in(context).with_associations(:links).first
    expect(owner.links.map(&:ref)).to eq(model.in(context).find(ref).links.map(&:ref))
    expect(owner.links.map(&:ref)).to eq([ref])
  end


  it "skips empty intermediate batches and clears a destroyed owner's cache" do
    person(1)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      statements << args.last[:sql] if args.last[:sql].match?(/SELECT .*spec_kg_nodes/i)
    end
    begin
      owner = ModelSpec::Person.in(ctx(4)).with_associations(known: :known_by).first
      expect(statements.size).to eq(2) # root + empty known; known_by is skipped
      expect(owner.known.to_a).to eq([])
      expect(owner.known.to_a).to be_frozen
      owner.destroy(writer: owner.context.trusted_writer)
      expect(owner.instance_variable_get(:@association_cache)).to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  it "serves cached terminals and bypasses the cache for every modifier" do
    a = person(1); t = project(1, title: "T")
    link(:REVIEWED, a, t, 1, score: 1)
    owner = people.with_associations(:reviewed_projects).first
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      statements << args.last[:sql] if args.last[:sql].match?(/SELECT .*spec_kg_nodes/i)
    end
    begin
      relation = owner.reviewed_projects
      expect(relation.count).to eq(1)
      expect(relation.exists?).to be(true)
      relation.first; relation.first(1); relation.to_a; relation.pluck(:title)
      expect(statements).to be_empty
      [relation.where(title: "T"), relation.order(:title), relation.limit(1), relation.offset(0),
       relation.rel_where(score: 1), relation.with_rel].each do |modified|
        before = statements.size
        modified.to_a
        expect(statements.size - before).to eq(1)
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

end
