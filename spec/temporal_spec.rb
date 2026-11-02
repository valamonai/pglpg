# frozen_string_literal: true

RSpec.describe "temporal edge validity (ADR-0013)" do
  let(:graph) do
    Pglpg::Graph.define(:temporal_spec) do
      column :classification, :integer, null: false
      node(:P) { property :name, :string }
      edge(:T, from: :P, to: :P, temporal: true) { property :role, :string }
      edge :U, from: :P, to: :P, temporal: true, unique: :pair
      edge :S, from: :P, to: :P, temporal: true, symmetric: true, allow_self_loops: true
      edge :N, from: :P, to: :P
    end
  end
  let(:write_ctx) { graph.for(viewer: Viewer.new(4)) }
  let(:date) { Date.new(2020, 6, 1) }
  let(:dated) { graph.for(viewer: Viewer.new(2), as_of: date) }
  let(:any) { graph.for(viewer: Viewer.new(2), as_of: :any) }
  let(:a) { write_ctx.insert_node(:P, properties: { name: "A" }, attrs: { classification: 1 }) }
  let(:b) { write_ctx.insert_node(:P, properties: { name: "B" }, attrs: { classification: 1 }) }
  let(:c) { write_ctx.insert_node(:P, properties: { name: "C" }, attrs: { classification: 1 }) }

  before { graph.storage.create! }

  def edge(from = a, to = b, type: :T, level: 1, **bounds)
    write_ctx.trusted_writer.insert_edge(type, from:, to:, attrs: { classification: level }, **bounds)
  end

  def query(context = dated, start = a, type = :T, direction = :out)
    context.match.node(:a, ref: start).public_send(direction, type, :b, :P, edge: :e).return(:b, :e)
  end

  [
    [nil, nil, true], [Date.new(2020, 6, 1), nil, true],
    [nil, Date.new(2020, 6, 1), false],
    [Date.new(2020, 5, 31), Date.new(2020, 6, 2), true],
    [Date.new(2020, 6, 2), nil, false], [nil, Date.new(2020, 5, 31), false]
  ].each do |lower, upper, included|
    it "filters [#{lower}, #{upper}) at exact boundaries" do
      ref = edge(valid_from: lower, valid_to: upper)
      expect(dated.find(ref)&.ref).to eq(included ? ref : nil)
      expect(query.count).to eq(included ? 1 : 0)
      expect(query.exists?).to eq(included)
      expect(query.distinct.limit(1).offset(0).first&.fetch(:e)&.ref).to eq(included ? ref : nil)
      expect(any.find(ref).ref).to eq(ref)
    end
  end

  it "uses one date on every hop, in both directions, with named edge conditions" do
    e1 = edge(a, b, valid_from: nil, valid_to: Date.new(2021, 1, 1))
    edge(b, c, valid_from: Date.new(2021, 1, 1))
    expect(query(dated, b, :T, :in).first[:e].ref).to eq(e1)
    q = dated.match.node(:a, ref: a).out(:T, :b).out(:T, :c).return(:c)
    expect(q.to_a).to eq([])
    expect(q.count).to eq(0)
    expect(query.where(e: { role: nil }).count).to eq(1)
    expect(query.explain(analyze: true, buffers: true)).not_to be_empty
  end

  it "filters both symmetric orientations and permits a loop once" do
    active = edge(b, a, type: :S, valid_from: nil)
    edge(b, c, type: :S, valid_from: Date.new(2021, 1, 1))
    loop_ref = edge(a, a, type: :S, valid_from: nil)
    expect(query(dated, a, :S, :both).map { _1[:e].ref }).to contain_exactly(active, loop_ref)
    expect(query(dated, b, :S, :both).map { _1[:b].ref }).to eq([a])
    r = dated.reachable(from: b, via: [:S], direction: :both, max_depth: 3, max_nodes: 5)
    expect(r.nodes).to eq([[a, 1]])
  end

  it "keeps timeless edges in a mixed traversal and dates minimum depth and completeness" do
    edge(a, b, valid_from: nil)
    edge(b, c, type: :N)
    edge(a, c, valid_from: nil, valid_to: Date.new(2020, 1, 1)) # expired shortcut
    r = dated.reachable(from: a, via: %i[T N], max_depth: 3, max_nodes: 2)
    expect(r.nodes).to eq([[b, 1], [c, 2]])
    expect(r.complete?).to be(true)
    cap = dated.reachable(from: a, via: %i[T N], max_depth: 3, max_nodes: 1)
    expect([cap.nodes, cap.complete?, cap.stopped_at_depth]).to eq([[[b, 1]], false, 1])
    expect(query(dated, b, :N).count).to eq(1)
  end

  it "requires a schema-based read mode identically for missing, hidden and visible edge Refs" do
    visible = edge(valid_from: nil)
    hidden = edge(valid_from: nil, level: 3)
    context = graph.for(viewer: Viewer.new(2))
    expect(context.find(a).ref).to eq(a)
    expect(query(context, a, :N).count).to eq(0)
    [visible, hidden, graph.ref(:edge, 9_999_999)].each do |ref|
      expect { context.find(ref) }.to raise_error(Pglpg::TemporalModeRequired)
    end
    %i[to_a count exists? first to_sql explain].each do |terminal|
      expect { query(context).public_send(terminal) }.to raise_error(Pglpg::TemporalModeRequired)
    end
    expect { context.reachable(from: a, via: [:T], max_depth: 1, max_nodes: 5) }.to raise_error(Pglpg::TemporalModeRequired)
    expect(context.reachable(from: a, via: [:N], max_depth: 1, max_nodes: 5).nodes).to eq([])
  end

  [DateTime.new(2020, 1, 1), Time.utc(2020), "2020-01-01", :today, Date.new(0), Date.new(10000)].each do |bad|
    it "rejects #{bad.inspect} as a context date before SQL" do
      expect { graph.for(viewer: Viewer.new(2), as_of: bad) }.to raise_error(ArgumentError)
    end
  end

  it "supports both finite extremes and copies mutable Date inputs" do
    [Date.new(1, 1, 1), Date.new(9999, 12, 31)].each do |bound|
      ref = edge(valid_from: bound)
      context = graph.for(viewer: Viewer.new(2), as_of: bound)
      expect(context.as_of).to be_frozen
      expect(context.as_of).not_to equal(bound)
      expect(context.find(ref).valid_from.iso8601).to eq(bound.iso8601)
    end
  end

  it "validates exact bound types, empty/reversed intervals and finite range" do
    [DateTime.new(2020), Time.utc(2020), "2020-01-01", Date.new(0), Date.new(10000)].each do |bad|
      expect { edge(valid_from: bad) }.to raise_error(Pglpg::ValidationError)
    end
    expect { edge(valid_from: date, valid_to: date) }.to raise_error(Pglpg::ValidationError)
    expect { edge(valid_from: date + 1, valid_to: date) }.to raise_error(Pglpg::ValidationError)
    expect { edge }.to raise_error(ArgumentError, /valid_from/)
    expect { edge(type: :N, valid_from: nil) }.to raise_error(ArgumentError, /not temporal/)
    expect { edge(type: :N, valid_to: nil) }.to raise_error(ArgumentError, /not temporal/)
  end

  it "preserves omitted update bounds and explicitly clears bounds in an ordinary context" do
    ref = edge(valid_from: date, valid_to: date + 2)
    write_ctx.update_edge(ref, properties: { role: "lead" })
    expect(any.find(ref).valid_from).to eq(date)
    write_ctx.update_edge(ref, valid_from: nil)
    expect(any.find(ref).valid_from).to be_nil
    expect(any.find(ref).valid_to).to eq(date + 2)
    expect { write_ctx.update_edge(ref, valid_from: date + 3) }.to raise_error(Pglpg::ValidationError)
    write_ctx.update_edge(ref, valid_to: nil)
    expect(any.find(ref).valid_to).to be_nil
    expect(any.find(edge(type: :N)).temporal?).to be(false)
  end

  it "keeps pair uniqueness for life and validates upsert input without disclosing occupancy" do
    refs = [b, c, write_ctx.insert_node(:P, attrs: { classification: 1 })]
    edge(a, refs[0], type: :U, valid_from: nil)
    edge(a, refs[1], type: :U, valid_from: nil, level: 3)
    w = graph.for(viewer: Viewer.new(3)).trusted_writer
    refs.each do |to|
      expect { w.upsert_edge(:U, from: a, to:, attrs: { classification: 1 }) }.to raise_error(ArgumentError, /valid_from/)
    end
    ref = w.upsert_edge(:U, from: a, to: b, valid_from: date, valid_to: date + 2, attrs: { classification: 1 })
    expect(w.upsert_edge(:U, from: a, to: b, valid_from: nil, attrs: { classification: 1 })).to eq(ref)
    expect([any.find(ref).valid_from, any.find(ref).valid_to]).to eq([nil, date + 2])
    w.upsert_edge(:U, from: a, to: b, valid_from: date, valid_to: nil, attrs: { classification: 1 })
    expect(any.find(ref).valid_to).to be_nil
    expect { w.insert_edge(:U, from: a, to: b, valid_from: date + 10, attrs: { classification: 1 }) }.to raise_error(Pglpg::WriteRejected)
    one = edge(valid_from: date, valid_to: date + 1)
    two = edge(valid_from: date + 2)
    overlap = edge(valid_from: date)
    expect([one, two, overlap].uniq.size).to eq(3)
  end

  it "exposes requested bound values and presence to both policy callbacks" do
    ref = edge(valid_from: nil)
    requests = []
    allow(ClearanceWritePolicy).to receive(:authorize?).and_wrap_original { |original, req| requests << req; original.call(req) }
    write_ctx.update_edge(ref, valid_from: nil, properties: { role: "x" })
    req = requests.last
    expect(req.validity).to eq(valid_from: nil)
    expect(req.validity_supplied).to eq(valid_from: true, valid_to: false)
    expect(req.validity).to be_frozen
  end

  it "checks the actual interval after a concurrent change and suppresses stored-row constraint details" do
    ref = edge(valid_from: nil, valid_to: date + 10)
    allow(ClearanceWritePolicy).to receive(:authorize?).and_wrap_original do |original, req|
      graph.connection.execute("UPDATE temporal_spec_edges SET valid_to = DATE '2020-06-02' WHERE id = #{ref.id}")
      original.call(req)
    end
    expect { write_ctx.update_edge(ref, valid_from: date + 2) }.to raise_error(Pglpg::ValidationError) { |e|
      expect(e.message).to eq("write violates schema constraints")
      expect(e.cause).to be_nil
    }
    expect(graph.connection.select_value("SELECT 1")).to eq(1)
    expect(any.find(ref).valid_from).to be_nil
  end

  it "rejects missing temporal mode and required upsert input without SQL" do
    start = a
    finish = b
    unspecified = graph.for(viewer: Viewer.new(2))
    writer = write_ctx.trusted_writer
    statements = []
    capture = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
      expect { query(unspecified, start).count }.to raise_error(Pglpg::TemporalModeRequired)
      expect { unspecified.find(graph.ref(:edge, 999)) }.to raise_error(Pglpg::TemporalModeRequired)
      expect { writer.upsert_edge(:U, from: start, to: finish) }.to raise_error(ArgumentError)
      expect { dated.update_edge(graph.ref(:edge, 999)) }.to raise_error(Pglpg::ReadOnlyContext)
    end
    expect(statements).to eq([])
  end

  it "reserves validity names in temporal graphs rather than silently adopting application metadata" do
    expect do
      Pglpg::Graph.define(:invalid_temporal_columns) do
        node :P
        edge_column :valid_from, :date
        edge :T, from: :P, to: :P, temporal: true
      end
    end.to raise_error(Pglpg::SchemaError, /reserved temporal/)
    expect do
      Pglpg::Graph.define(:invalid_temporal_properties) do
        node(:P) { property :valid_to, :date }
        edge :T, from: :P, to: :P, temporal: true
      end
    end.to raise_error(Pglpg::SchemaError, /reserved temporal/)
  end

  it "refuses all dated context writes before SQL and authorization" do
    node = a
    ref = edge(valid_from: nil)
    expect(ClearanceWritePolicy).not_to receive(:authorize?)
    calls = [
      -> { dated.insert_node(:P) }, -> { dated.update_node(node) },
      -> { dated.insert_edge(:T, from: node, to: node) }, -> { dated.update_edge(ref) },
      -> { dated.delete_edge(ref) }, -> { dated.trusted_writer },
      -> { Pglpg::Writer.new(dated, trusted: true) }
    ]
    calls.each { |call| expect(&call).to raise_error(Pglpg::ReadOnlyContext) }
  end

  it "enforces interval constraints through raw SQL and keeps the caller transaction usable" do
    ref = edge(valid_from: nil)
    db = graph.connection
    ["valid_from = DATE '2021-01-01', valid_to = DATE '2020-01-01'", "valid_from = 'infinity'", "valid_to = DATE '10000-01-01'"].each do |set|
      expect { db.transaction(requires_new: true) { db.execute("UPDATE temporal_spec_edges SET #{set} WHERE id = #{ref.id}") } }.to raise_error(ActiveRecord::StatementInvalid)
      expect(db.select_value("SELECT 1")).to eq(1)
    end
    plain = edge(type: :N)
    expect { db.transaction(requires_new: true) { db.execute("UPDATE temporal_spec_edges SET valid_from = DATE '2020-01-01' WHERE id = #{plain.id}") } }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "keeps observations unchanged after hidden bridges, expired edges and out-of-date shortcuts are added" do
    edge(a, b, valid_from: nil)
    edge(b, c, valid_from: nil)
    observe = lambda do
      q = query.order(b: :name)
      [q.map { [_1[:b].ref, _1[:e].ref] }, q.count, q.exists?, q.limit(1).offset(1).to_a,
       dated.reachable(from: a, via: [:T], max_depth: 3, max_nodes: 2),
       dated.reachable(from: a, via: [:T], max_depth: 3, max_nodes: 1)]
    end
    before = observe.call
    h = write_ctx.insert_node(:P, attrs: { classification: 3 })
    edge(a, h, valid_from: nil)
    edge(h, c, valid_from: nil)
    hidden = edge(a, c, valid_from: nil, level: 3)
    expired = edge(a, c, valid_from: nil, valid_to: date)
    edge(a, b, valid_from: date + 1)
    expect(observe.call).to eq(before)
    expect(dated.find(hidden)).to be_nil
    expect(dated.find(expired)).to be_nil
  end
end
