# frozen_string_literal: true

RSpec.describe "text MATCH" do
  def refs(query)
    query.to_a.map { |row| row.transform_values(&:ref) }
  end

  it "builds a frozen node query without SQL and binds hostile strings as data" do
    name = "O'Brien'; DELETE FROM spec_kg_nodes; --"
    target = person(name:)
    person(name: "Other")
    context = ctx(1)
    text = "match (p:Person) where p.name = $name return p;"
    params = { "name" => name }
    statements = []
    query = nil
    ActiveSupport::Notifications.subscribed(->(*args) { statements << args.last[:sql] }, "sql.active_record") do
      query = context.parse_match(text, params:)
    end
    expect(statements).to be_empty
    expect(query).to be_a(Pglpg::Query).and be_frozen
    expect(query.context).to equal(context)
    expected = context.match.node(:p, :Person).where(p: { name: }).return(:p)
    expect(query.to_sql).to eq(expected.to_sql)
    expect(context.parse_match(text, params:).to_sql).to eq(query.to_sql)
    expect(query.to_sql.first).not_to include(name)
    expect(refs(query)).to eq([{ p: target }])
  end

  it "preserves incoming and outgoing hops, repeated filters, binds, order and limit" do
    a = person(name: "A")
    b = person(name: "A")
    j = project(title: "Apollo")
    l = ctx.insert_node(:Location, attrs: { classification: 1 })
    w = trusted.insert_edge(:WORKS_ON, from: a, to: j, properties: { role: "A" }, attrs: { classification: 1 })
    trusted.insert_edge(:WORKS_ON, from: b, to: j, properties: { role: "B" }, attrs: { classification: 1 })
    trusted.insert_edge(:BASED_AT, from: j, to: l, attrs: { classification: 1 })

    context = ctx(1)
    query = context.parse_match(<<~GQL, params: { name: "A" })
      MATCH (j:Project)<-[w:WORKS_ON]-(p:Person)-[:WORKS_ON]->(k:Project)-[:BASED_AT]->(l:Location)
      WHERE p.name = $name AND w.role = $name AND p.name = $name
      RETURN DISTINCT p, w, l ORDER BY p.name DESC LIMIT 3
    GQL
    # The default match mode requires different edges of the same type.
    second = project(title: "Borealis")
    trusted.insert_edge(:WORKS_ON, from: a, to: second, attrs: { classification: 1 })
    trusted.insert_edge(:BASED_AT, from: second, to: l, attrs: { classification: 1 })
    expected = context.match.node(:j, :Project).in(:WORKS_ON, :p, :Person, edge: :w)
                      .out(:WORKS_ON, :k, :Project).out(:BASED_AT, :l, :Location)
                      .where(p: { name: "A" }).where(w: { role: "A" }).where(p: { name: "A" })
                      .return(:p, :w, :l).distinct.order(p: { name: :desc }).limit(3)
    expect(query.to_sql).to eq(expected.to_sql)
    expect(refs(query)).to eq(refs(expected))
    expect(refs(query)).to eq([{ p: a, w:, l: }])
  end

  it "keeps symmetric orientations and self-loop multiplicity" do
    a, b = person, person
    link = ctx.insert_edge(:SAME_AS, from: a, to: b, attrs: { classification: 1 })
    loop_ref = ctx.insert_edge(:SAME_AS, from: a, to: a, attrs: { classification: 1 })
    context = ctx(1)
    pattern = "MATCH (a:Person)~[e:SAME_AS]~(b:Person)"
    query = context.parse_match("#{pattern} RETURN e")
    expected = context.match.node(:a, :Person).both(:SAME_AS, :b, :Person, edge: :e).return(:e)
    expect(query.to_sql).to eq(expected.to_sql)
    expect(refs(query)).to eq(refs(expected))
    expect(refs(query)).to contain_exactly({ e: link }, { e: link }, { e: loop_ref })
    expect(refs(context.parse_match("#{pattern} RETURN DISTINCT e"))).to contain_exactly({ e: link }, { e: loop_ref })
  end

  it "keeps the context's temporal mode and visibility on a temporal edge" do
    graph = Pglpg::Graph.define(:parsed_temporal) do
      column :classification, :integer, null: false
      node(:P) { property :name, :string }
      edge :T, from: :P, to: :P, temporal: true
    end
    graph.storage.create!
    viewer = Viewer.new(1)
    writer = graph.for(viewer: Viewer.new(4))
    a = writer.insert_node(:P, properties: { name: "A" }, attrs: { classification: 1 })
    b = writer.insert_node(:P, attrs: { classification: 1 })
    hidden = writer.insert_node(:P, attrs: { classification: 4 })
    date = Date.new(2020, 1, 1)
    writer.insert_edge(:T, from: a, to: b, attrs: { classification: 1 }, valid_from: date)
    writer.insert_edge(:T, from: a, to: b, attrs: { classification: 1 }, valid_from: nil, valid_to: date)
    writer.insert_edge(:T, from: a, to: b, attrs: { classification: 4 }, valid_from: nil)
    writer.insert_edge(:T, from: a, to: hidden, attrs: { classification: 1 }, valid_from: nil)
    text = "MATCH (a:P)-[e:T]->(b:P) WHERE a.name = $name RETURN b, e"
    [date, :any].zip([1, 2]).each do |as_of, count|
      context = graph.for(viewer:, as_of:)
      query = context.parse_match(text, params: { name: "A" })
      expected = context.match.node(:a, :P).out(:T, :b, :P, edge: :e).where(a: { name: "A" }).return(:b, :e)
      expect(query.to_sql).to eq(expected.to_sql)
      expect(refs(query)).to eq(refs(expected))
      expect(query.count).to eq(count)
    end
    query = graph.for(viewer:).parse_match(text, params: { name: "A" })
    expect { query.to_a }.to raise_error(Pglpg::TemporalModeRequired)
  end

  it "enforces the row budget at execution when LIMIT is absent" do
    person
    person
    Pglpg.configure { _1.max_rows = 1 }
    context = ctx
    expect { context.parse_match("MATCH (p:Person) RETURN p").to_a }.to raise_error(Pglpg::TooManyRows)
    expect(context.parse_match("MATCH (p:Person) RETURN p LIMIT 1").to_a.size).to eq(1)
    expect { context.parse_match("MATCH (p:Person) RETURN p LIMIT 2") }
      .to raise_error(Pglpg::ParseError) { |error| expect(error.code).to eq(:limit_exceeded) }
  end

  it "uses the existing statement timeout at execution" do
    Pglpg.configure { _1.statement_timeout = 1234 }
    person
    context = ctx
    policy = Object.new
    def policy.node(_table, _viewer) = Arel.sql("current_setting('statement_timeout') = '1234ms'")
    Pglpg.configure { _1.visibility = policy }
    expect(context.parse_match("MATCH (p:Person) RETURN p").to_a.size).to eq(1)
    expect(ActiveRecord::Base.connection.select_value("SHOW statement_timeout")).to eq("0")
  end

  [
    ["MATCH (p:Person)", {}, :syntax, "EOF"],
    ["MATCH (p:Person) RETURN p;\vMATCH (q:Person) RETURN q", {}, :syntax, "MATCH"],
    ["MATCH (match:Person) RETURN match", {}, :syntax, "match"],
    ["MATCH (_p:Person) RETURN _p", {}, :syntax, "_p"],
    ["MATCH (p:Person)-[:KNOWS]->(p:Person) RETURN p", {}, :syntax, "p"],
    ["MATCH (p:Person) RETURN p LIMIT 0", {}, :syntax, "0"],
    ["MATCH (p:Person)-[:KNOWS]->(q:Person) RETURN DISTINCT p ORDER BY q.name", {}, :syntax, "q"],
    ["MATCH (p:Person)//comment\nRETURN p", {}, :unsupported, "//"],
    ["MATCH (p:Person|Employee) RETURN p", {}, :unsupported, "|"],
    ["MATCH (p:Person)-[:KNOWS]->{1,3}(q:Person) RETURN q", {}, :unsupported, "{"],
    ["MATCH (p:Person),(q:Person) RETURN q", {}, :unsupported, ","],
    ["MATCH (p:Person) RETURN p.name", {}, :unsupported, "."],
    ["MATCH (p:Person) RETURN p AS person", {}, :unsupported, "AS"],
    ["MATCH (p:Person) RETURN p ORDER BY p.name, p.rank", {}, :unsupported, ","],
    ["MATCH (p:Person) WHERE NOT p.name = $n RETURN p", { n: "A" }, :unsupported_condition, "NOT"],
    ["MATCH (p:Person) WHERE ANY(x IN p.tags) RETURN p", {}, :unsupported_condition, "ANY"],
    ["MATCH (p:Person) WHERE p.name STARTS WITH $n RETURN p", { n: "A" }, :unsupported_condition, "STARTS"],
    ["MATCH (p:Person) WHERE p.name ENDS WITH $n RETURN p", { n: "A" }, :unsupported_condition, "ENDS"],
    ["MATCH (p:Person) WHERE p.name CONTAINS $n RETURN p", { n: "A" }, :unsupported_condition, "CONTAINS"],
    ["MATCH (p:Person) WHERE p.name = $n XOR p.rank = $r RETURN p", { n: "A", r: 1 }, :unsupported_condition, "XOR"],
    ["MATCH (p:Person) RETURN p OFFSET 1", {}, :unsupported, "OFFSET"],
    ["MATCH (p:Person)~[:KNOWS]~(q:Person) RETURN q", {}, :unsupported, "~"],
    ["MATCH (p:Person)-[:FRIEND]->(q:Person) RETURN q", {}, :unsupported, "-"],
    ["MATCH (p:Person) RETURN p ORDER BY p.tags", {}, :unsupported, "tags"],
    ["MATCH (p:Person) WHERE p.rank > $n RETURN p", { n: 3 }, :unsupported_condition, ">"],
    ["MATCH (p:Person) WHERE p.rank = 3 RETURN p", {}, :unsupported_condition, "3"],
    ["MATCH (p:Person) WHERE p.name IS NULL RETURN p", {}, :unsupported_condition, "IS"],
    ["MATCH (p:Person) WHERE p.name = $n OR p.name = $n RETURN p", { n: "A" }, :unsupported_condition, "OR"],
    ["MATCH (p:Missing) RETURN p", {}, :unknown_name, "Missing"],
    ["MATCH (p:Person)-[:MISSING]->(q:Person) RETURN q", {}, :unknown_name, "MISSING"],
    ["MATCH (p:Person) RETURN P", {}, :unknown_name, "P"],
    ["MATCH (p:Person) RETURN p ORDER BY p.classification", {}, :unknown_name, "classification"],
    ["MATCH (p:Person) WHERE p.extra = $n RETURN p", { n: "A" }, :unknown_name, "extra"],
    ["MATCH (p:Person) WHERE p.name = $n RETURN p", {}, :parameter, "$n"],
    ["MATCH (p:Person) WHERE p.name = $n RETURN p", { "n" => "A", n: "A" }, :parameter, "$n"],
    ["MATCH (p:Person) WHERE p.name = $n RETURN p", { n: nil }, :parameter, "$n"],
    ["MATCH (p:Person) WHERE p.name = $n RETURN p", { n: ["A"] }, :parameter, "$n"],
    ["MATCH (p:Person) WHERE p.name = $n RETURN p", { n: Pglpg.ne("A") }, :parameter, "$n"],
    ["MATCH (p:Person) WHERE p.rank = $n RETURN p", { n: "private value" }, :parameter, "$n"],
    ["MATCH (p:Person) RETURN p", { unused: true }, :parameter, nil]
  ].each do |text, params, code, token|
    it "reports #{code} for #{text.inspect} (#{params.keys.inspect}, #{token.inspect})" do
      statements = []
      errors = [false, true].map do |seed|
        person(name: "A", rank: 3) if seed
        failure = nil
        ActiveSupport::Notifications.subscribed(->(*args) { statements << args.last[:sql] }, "sql.active_record") do
          expect { ctx.parse_match(text, params:) }.to raise_error(Pglpg::ParseError) { |error| failure = error }
        end
        expect([failure.code, failure.token]).to eq([code, token])
        expect(failure.message).not_to include("private value")
        expect(failure.cause).to be_nil
        [failure.position, failure.line, failure.column, failure.message]
      end
      expect(errors.first).to eq(errors.last)
      expect(statements).to be_empty
    end
  end

  it "reports byte positions and one-based lines and columns" do
    expect { ctx.parse_match("MATCH (p:Person)\nRETURN q") }.to raise_error(Pglpg::ParseError) do |error|
      expect([error.position, error.line, error.column, error.token]).to eq([24, 2, 8, "q"])
    end
    expect { ctx.parse_match(nil) }.to raise_error(ArgumentError)
    ["MATCH".b, "MATCH \xFF"].each do |text|
      expect { ctx.parse_match(text) }.to raise_error(Pglpg::ParseError) { |error| expect(error.code).to eq(:syntax) }
    end
    expect(ctx.parse_match("MATCH (p:Person) RETURN p".encode("US-ASCII"))).to be_a(Pglpg::Query)
  end

  it "permits identifier spellings outside their keyword positions" do
    graph = Pglpg::Graph.define(:keyword_match) do
      node(:Return) { property :where, :string }
    end
    context = graph.for(viewer: Viewer.new(1))
    parsed = context.parse_match("MATCH (not:Return) WHERE not.where = $match RETURN not", params: { match: "A" })
    expect(parsed.to_sql).to eq(context.match.node(:not, :Return).where(not: { where: "A" }).return(:not).to_sql)
  end

  it "checks structural limits and rejects oversized parameter maps before validating their keys" do
    base = "MATCH (p:Person) RETURN p"
    oversized_hops = "MATCH (p:Person)" + (1..9).map { |i| "-[:KNOWS]->(p#{i}:Person)" }.join + " RETURN p"
    oversized_predicates = "MATCH (p:Person) WHERE " + Array.new(33, 'p.name = $n').join(" AND ") + " RETURN p"
    [
      [base.ljust(8193), {}],
      [oversized_hops, {}],
      [oversized_predicates, { n: "A" }],
      [base, (1..33).to_h { |i| ["p#{i}", i] }]
    ].each do |text, params|
      expect { ctx.parse_match(text, params:) }.to raise_error(Pglpg::ParseError) do |error|
        expect(error.code).to eq(:limit_exceeded)
      end
    end
    expect(ctx.parse_match(base.ljust(8192))).to be_a(Pglpg::Query)
    expect(ctx.parse_match(oversized_hops.sub("-[:KNOWS]->(p9:Person)", ""))).to be_a(Pglpg::Query)
    params = (1..32).to_h { |i| ["n#{i}", i] }
    filters = params.keys.map { |name| "p.rank = $#{name}" }.join(" AND ")
    expect(ctx.parse_match("MATCH (p:Person) WHERE #{filters} RETURN p", params:)).to be_a(Pglpg::Query)
  end
end
