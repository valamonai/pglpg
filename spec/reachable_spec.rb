# frozen_string_literal: true

# Context#reachable: the contract in task "0.2: reachable API" and ADR-0009.
RSpec.describe "reachable" do
  def knows(from, to, level = 1) = trusted.insert_edge(:KNOWS, from:, to:, attrs: { classification: level })

  def friend(a, b, level = 1) = trusted.insert_edge(:FRIEND, from: a, to: b, attrs: { classification: level })

  def reach(from, via: %i[KNOWS], max_depth: 3, max_nodes: 100, clearance: 4, **opts)
    ctx(clearance).reachable(from:, via:, max_depth:, max_nodes:, **opts)
  end

  def result(nodes, complete: true, stopped_at_depth: nil)
    Pglpg::Reachability.new(nodes:, complete:, stopped_at_depth:)
  end

  # Created in this order, so ids ascend a < b < c < d.
  let!(:a) { person(1, name: "A") }
  let!(:b) { person(1, name: "B") }
  let!(:c) { person(1, name: "C") }
  let!(:d) { person(1, name: "D") }

  describe "graph shapes" do
    it "returns each node at its depth along a chain, up to max_depth" do
      knows(a, b)
      knows(b, c)
      knows(c, d)
      expect(reach(a)).to eq(result([[b, 1], [c, 2], [d, 3]]))
      expect(reach(a, max_depth: 2)).to eq(result([[b, 1], [c, 2]]))
    end

    it "orders each level by id and freezes the result" do
      knows(a, d)
      knows(a, c)
      knows(a, b)
      r = reach(a)
      expect(r.nodes).to eq([[b, 1], [c, 1], [d, 1]])
      expect(r.nodes).to be_frozen
      expect(r.nodes.first).to be_frozen
    end

    it "counts a node reached along a diamond once, before the budget" do
      knows(a, b)
      knows(a, c)
      knows(b, d)
      knows(c, d)
      expect(reach(a, max_nodes: 3)).to eq(result([[b, 1], [c, 1], [d, 2]]))
    end

    it "returns the minimum depth when a short and a long route compete" do
      knows(a, b)
      knows(b, c)
      knows(c, d)
      knows(a, d)
      expect(reach(a)).to eq(result([[b, 1], [d, 1], [c, 2]]))
    end

    it "never returns the start, even through a cycle" do
      knows(a, b)
      knows(b, a)
      knows(b, c)
      expect(reach(a)).to eq(result([[b, 1], [c, 2]]))
    end

    it "follows parallel edges once" do
      knows(a, b)
      knows(a, b)
      expect(reach(a)).to eq(result([[b, 1]]))
    end

    it "ignores a self-loop on the start" do
      trusted.insert_edge(:SAME_AS, from: a, to: a, attrs: { classification: 1 })
      trusted.insert_edge(:SAME_AS, from: a, to: b, attrs: { classification: 1 })
      expect(reach(a, via: %i[SAME_AS], direction: :both)).to eq(result([[b, 1]]))
    end
  end

  describe "direction" do
    before do
      knows(a, b)
      knows(c, b)
      knows(d, c)
    end

    it "follows outgoing edges by default and incoming ones with :in" do
      expect(reach(b)).to eq(result([]))
      expect(reach(b, direction: :in)).to eq(result([[a, 1], [c, 1], [d, 2]]))
    end

    it "follows a symmetric type from both stored ends with :both" do
      friend(b, a)
      friend(c, b)
      expect(reach(a, via: %i[FRIEND], direction: :both)).to eq(result([[b, 1], [c, 2]]))
      expect(reach(c, via: %i[FRIEND], direction: :both)).to eq(result([[b, 1], [a, 2]]))
    end

    it "follows any listed type at every hop" do
      trusted.insert_edge(:MET, from: a, to: b, attrs: { classification: 1 })
      friend(b, c)
      expect(reach(a, via: %i[FRIEND MET], direction: :both)).to eq(result([[b, 1], [c, 2]]))
    end

    it "keeps direction and symmetry apart, as match does" do
      expect { reach(a, via: %i[FRIEND]) }.to raise_error(ArgumentError, /symmetric/)
      expect { reach(a, via: %i[KNOWS], direction: :both) }.to raise_error(ArgumentError, /directed/)
      expect { reach(a, via: %i[KNOWS FRIEND]) }.to raise_error(ArgumentError, /symmetric/)
      expect { reach(a, via: %i[KNOWS FRIEND], direction: :both) }.to raise_error(ArgumentError, /directed/)
      expect { reach(a, direction: :sideways) }.to raise_error(ArgumentError, /direction/)
    end
  end

  describe "arguments" do
    it "rejects invalid budgets and edge types" do
      expect { reach(a, max_depth: 0) }.to raise_error(ArgumentError, /max_depth/)
      expect { reach(a, max_depth: 1.5) }.to raise_error(ArgumentError, /max_depth/)
      expect { reach(a, max_nodes: 0) }.to raise_error(ArgumentError, /max_nodes/)
      expect { reach(a, max_nodes: 1001) }.to raise_error(ArgumentError, /max_rows/)
      expect { reach(a, via: []) }.to raise_error(ArgumentError, /via/)
      expect { reach(a, via: %i[NOPE]) }.to raise_error(ArgumentError, /unknown edge type/)
    end

    it "accepts max_nodes up to max_rows" do
      knows(a, b)
      expect(reach(a, max_nodes: 1000)).to eq(result([[b, 1]]))
    end

    it "rejects deadlines that are not a positive, finite number" do
      [0, -1, Float::INFINITY, Float::NAN, "1", true].each do |deadline|
        expect { reach(a, deadline:) }.to raise_error(ArgumentError, /deadline/), deadline.inspect
      end
    end

    it "rejects refs that are not nodes of this graph" do
      edge = knows(a, b)
      expect { reach(edge) }.to raise_error(Pglpg::InvalidRef)
      expect { reach(Pglpg::Ref.new(graph: :other, kind: :node, id: a.id)) }.to raise_error(Pglpg::InvalidRef)
      expect { reach("spec_kg:node:1") }.to raise_error(Pglpg::InvalidRef)
    end
  end

  describe "start node" do
    it "gives the same empty, complete result for a hidden start and a missing one" do
      hidden = person(4)
      knows(hidden, a)
      missing = Kg.ref(:node, hidden.id + 1000)
      expect(reach(hidden, clearance: 2)).to eq(result([]))
      expect(reach(missing, clearance: 2)).to eq(result([]))
      expect(reach(hidden)).to eq(result([[a, 1]]))
    end
  end

  describe "visibility" do
    it "never traverses hidden nodes or edges, so a hidden shortcut cannot lower a depth" do
      h = person(4)
      knows(a, b)
      knows(b, c)
      knows(a, c, 4)     # hidden shortcut edge
      knows(a, h)        # visible edge to a hidden node...
      knows(h, d)        # ...that is the only route to d
      expect(reach(a, clearance: 2)).to eq(result([[b, 1], [c, 2]]))
      expect(reach(a)).to eq(result([[b, 1], [c, 1], [h, 1], [d, 2]]))
    end
  end

  describe "completeness" do
    it "truncates an overflowing level to the first max_nodes nodes" do
      knows(a, b)
      knows(a, c)
      knows(a, d)
      expect(reach(a, max_nodes: 2)).to eq(result([[b, 1], [c, 1]], complete: false, stopped_at_depth: 1))
    end

    it "reports the depth of the last returned node, not of the probe" do
      knows(a, b)
      knows(b, c)
      expect(reach(a, max_nodes: 1, max_depth: 2)).to eq(result([[b, 1]], complete: false, stopped_at_depth: 1))
    end

    it "is complete when exactly full and nothing new is reachable within max_depth" do
      knows(a, b)
      knows(b, a)
      expect(reach(a, max_nodes: 1, max_depth: 3)).to eq(result([[b, 1]]))
      knows(b, c)
      expect(reach(a, max_nodes: 1, max_depth: 1)).to eq(result([[b, 1]]))
    end

    it "does not count hidden nodes toward the budget or the probe" do
      knows(a, b)
      knows(b, person(4))
      expect(reach(a, max_nodes: 1, clearance: 2)).to eq(result([[b, 1]]))
    end
  end

  describe "statement and timeout" do
    # Makes a node visible only when the statement runs under +expected+ as
    # its statement_timeout, so a result proves which timeout applied.
    TimeoutProbe = Struct.new(:expected) do
      def node(_table, _viewer) = Arel.sql("current_setting('statement_timeout') = '#{expected}'")

      def edge(_table, _viewer) = Arel.sql("TRUE")
    end

    # Each node check sleeps longer than the deadlines used below.
    module SlowPolicy
      def self.node(_table, _viewer) = Arel.sql("(SELECT true FROM pg_sleep(0.05))")

      def self.edge(_table, _viewer) = Arel.sql("TRUE")
    end

    def connection = ActiveRecord::Base.connection

    def session_timeout = connection.select_value("SELECT current_setting('statement_timeout')")

    def runs_under?(expected, statement_timeout:, deadline: nil)
      Pglpg.configuration.statement_timeout = statement_timeout
      Pglpg.configuration.visibility = TimeoutProbe.new(expected)
      reach(a, deadline:).nodes == [[b, 1]]
    end

    before do
      knows(a, b)
      connection.execute("SET LOCAL statement_timeout = '7s'")
    end

    it "uses the smaller of the configured timeout and the deadline" do
      expect(runs_under?("250ms", statement_timeout: 5000, deadline: 0.25)).to be(true)
      expect(runs_under?("200ms", statement_timeout: 200, deadline: 2)).to be(true)
      expect(runs_under?("5s", statement_timeout: 5000)).to be(true)
      expect(runs_under?("5s", statement_timeout: 5000, deadline: 0.25)).to be(false)
    end

    it "uses the deadline alone when no timeout is configured, and 0 configures none" do
      expect(runs_under?("250ms", statement_timeout: nil, deadline: 0.25)).to be(true)
      expect(runs_under?("250ms", statement_timeout: 0, deadline: 0.25)).to be(true)
    end

    it "leaves the session timeout when neither is set" do
      expect(runs_under?("7s", statement_timeout: nil)).to be(true)
      expect(runs_under?("7s", statement_timeout: 0)).to be(true)
    end

    it "rounds a deadline up to whole milliseconds, never to 0" do
      expect(runs_under?("1ms", statement_timeout: nil, deadline: 0.0001)).to be(true)
      expect(runs_under?("300ms", statement_timeout: nil, deadline: 0.3)).to be(true)
      expect(runs_under?("2ms", statement_timeout: nil, deadline: Rational(3, 2000))).to be(true)
    end

    it "restores the previous timeout after a call" do
      reach(a, deadline: 0.5)
      expect(session_timeout).to eq("7s")
    end

    it "raises QueryTimeout, restores the timeout and leaves the caller's transaction usable" do
      Pglpg.configuration.visibility = SlowPolicy
      expect { reach(a, deadline: 0.01) }.to raise_error(Pglpg::QueryTimeout)
      expect(session_timeout).to eq("7s")
      expect(connection.select_value("SELECT 1")).to eq(1)
      Pglpg.configuration.visibility = ClearancePolicy
      expect(reach(a)).to eq(result([[b, 1]]))
    end

    it "runs inside a READ COMMITTED caller transaction" do
      expect(connection.select_value("SHOW transaction_isolation")).to eq("read committed")
      expect(reach(a)).to eq(result([[b, 1]]))
    end
  end
end
