# frozen_string_literal: true

# Start lists and measurement cells. A cell is fixture × shape × clearance;
# the shapes below are the same for every revision measured.
module Cells
  RANDOM_STARTS = 50
  HUB_STARTS = 3
  PROBE_STARTS = 10

  # Starts for one clearance, chosen in SQL (not through pglpg, so they are
  # the same for every revision) and only among nodes that viewer can see.
  # Orders are seeded through hashint8, so lists are stable across runs.
  def self.starts(conn, graph, clearance)
    n = graph.nodes_table
    e = graph.edges_table
    c = Integer(clearance)
    ids = ->(sql) { conn.select_values(sql).map(&:to_i) }
    visible_knows = <<~SQL
      SELECT DISTINCT e.source_id AS s, e.target_id AS t FROM #{e} e
      JOIN #{n} a ON a.id = e.source_id AND a.classification <= #{c}
      JOIN #{n} b ON b.id = e.target_id AND b.classification <= #{c}
      WHERE e.type = 'KNOWS' AND e.classification <= #{c} AND e.source_id <> e.target_id
    SQL
    # Starts with exactly one visible KNOWS neighbour B, split by whether B
    # leads anywhere new: the A → B and A → B → C graphs of the probe cells.
    probes = conn.select_rows(<<~SQL).map { [_1.to_i, _2] }
      WITH vk AS MATERIALIZED (#{visible_knows}),
      one AS (SELECT s, min(t) AS t FROM vk GROUP BY s HAVING count(*) = 1)
      SELECT one.s, count(vk.t) FILTER (WHERE vk.t <> one.s) > 0 AS deeper
      FROM one LEFT JOIN vk ON vk.s = one.t
      GROUP BY one.s ORDER BY hashint8(one.s + 42), one.s
    SQL
    {
      random: ids.(<<~SQL),
        SELECT id FROM #{n} WHERE key_label = 'Person' AND classification <= #{c}
        ORDER BY hashint8(id + 42), id LIMIT #{RANDOM_STARTS}
      SQL
      knows_hub: ids.(<<~SQL),
        SELECT s FROM (#{visible_knows}) vk GROUP BY s ORDER BY count(*) DESC, s LIMIT #{HUB_STARTS}
      SQL
      friend_hub: ids.(<<~SQL),
        SELECT x.p FROM (SELECT source_id AS p, target_id AS q, classification FROM #{e} WHERE type = 'FRIEND'
                         UNION ALL SELECT target_id, source_id, classification FROM #{e} WHERE type = 'FRIEND') x
        JOIN #{n} a ON a.id = x.p AND a.classification <= #{c}
        JOIN #{n} b ON b.id = x.q AND b.classification <= #{c}
        WHERE x.classification <= #{c} GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT #{HUB_STARTS}
      SQL
      probe_negative: probes.reject { _2 }.first(PROBE_STARTS).map(&:first),
      probe_positive: probes.select { _2 }.first(PROBE_STARTS).map(&:first)
    }
  end

  # id: shape name; starts: start list kind; run: the public call;
  # size: result size for workload checks; check: exact expectations per
  # start (nil when met); requires: API the revision must have.
  Cell = Data.define(:id, :starts, :run, :size, :check, :requires)

  ROWS = ->(r) { r.size }
  NONE = ->(_r) {}
  REACH = ->(r) { r.nodes.size }

  def self.cell(id, starts, run, size: ROWS, check: NONE, requires: nil) = Cell.new(id:, starts:, run:, size:, check:, requires:)

  # Expected Reachability of a probe start: one node at depth 1.
  def self.probe(complete:, stopped_at_depth:)
    lambda do |r|
      got = [r.nodes.map(&:last), r.complete, r.stopped_at_depth]
      want = [[1], complete, stopped_at_depth]
      "expected depths, complete, stopped_at_depth #{want.inspect}, got #{got.inspect}" unless got == want
    end
  end

  def self.reach(direction, via, max_depth, max_nodes)
    ->(g, ref) { g.reachable(from: ref, via:, direction:, max_depth:, max_nodes:) }
  end

  # An overflowing level: exactly max_nodes nodes, incomplete, stopped at
  # the depth of the last node returned, within max_depth.
  def self.overflow(max_depth:, max_nodes:)
    lambda do |r|
      depths = r.nodes.map(&:last)
      if r.complete then "expected an incomplete result"
      elsif r.nodes.size != max_nodes then "expected #{max_nodes} nodes, got #{r.nodes.size}"
      elsif r.stopped_at_depth.nil? then "expected stopped_at_depth, got nil"
      elsif r.stopped_at_depth != depths.last || r.stopped_at_depth > max_depth
        "stopped_at_depth #{r.stopped_at_depth} is not the last depth #{depths.last} within max_depth #{max_depth}"
      end
    end
  end

  # Complete within the requested depth: no stop depth, no deeper node.
  def self.complete(max_depth:)
    lambda do |r|
      if !r.complete || !r.stopped_at_depth.nil?
        "expected complete: true, stopped_at_depth: nil, got #{r.complete.inspect}, #{r.stopped_at_depth.inspect}"
      elsif r.nodes.any? { _1.last > max_depth }
        "a node deeper than max_depth #{max_depth}"
      end
    end
  end

  def self.all(graph)
    ref = ->(id) { graph.ref(:node, id) }
    reachable = ->(g) { g.respond_to?(:reachable) }
    [
      cell("find_by_key", :random, ->(g, id) { g.find_node(:Person, uid: "P#{id}") },
           size: ->(r) { r ? 1 : 0 }, check: ->(r) { "visible start not found" unless r }),
      cell("hop1", :random, ->(g, id) { g.match.node(:p, ref: ref.(id)).out(:INVOLVED_IN, :i, :Incident).limit(500).to_a }),
      cell("hop2", :random, lambda { |g, id|
        g.match.node(:p, ref: ref.(id)).out(:INVOLVED_IN, :i, :Incident).out(:OCCURRED_AT, :l, :Location).limit(500).to_a
      }),
      cell("hop3", :random, lambda { |g, id|
        g.match.node(:p, ref: ref.(id)).out(:KNOWS, :q, :Person).out(:INVOLVED_IN, :i, :Incident)
         .out(:OCCURRED_AT, :l, :Location).limit(500).to_a
      }),
      cell("hop3_hub", :knows_hub, lambda { |g, id|
        g.match.node(:p, ref: ref.(id)).out(:KNOWS, :q, :Person).out(:INVOLVED_IN, :i, :Incident)
         .out(:OCCURRED_AT, :l, :Location).limit(500).to_a
      }),
      cell("hop1_filtered", :random, lambda { |g, id|
        g.match.node(:p, ref: ref.(id)).out(:INVOLVED_IN, :i, :Incident).where(i: { severity: Pglpg.gte(4) }).limit(500).to_a
      }),
      cell("count2_hub", :knows_hub, lambda { |g, id|
        g.match.node(:p, ref: ref.(id)).out(:KNOWS, :q, :Person).out(:MEMBER_OF, :o, :Organization).count
      }, size: ->(r) { r }),
      cell("sym1", :random, ->(g, id) { g.match.node(:p, ref: ref.(id)).both(:FRIEND, :q, :Person).limit(500).to_a }),
      cell("sym2", :random, lambda { |g, id|
        g.match.node(:p, ref: ref.(id)).both(:FRIEND, :q, :Person).both(:FRIEND, :r, :Person).limit(500).to_a
      }),
      cell("sym2_hub", :friend_hub, lambda { |g, id|
        g.match.node(:p, ref: ref.(id)).both(:FRIEND, :q, :Person).both(:FRIEND, :r, :Person).limit(500).to_a
      }),
      # Overflowing level: more visible nodes than max_nodes.
      cell("reach_knows_overflow", :knows_hub, ->(g, id) { reach(:out, %i[KNOWS], 3, 500).(g, ref.(id)) },
           size: REACH, check: overflow(max_depth: 3, max_nodes: 500), requires: reachable),
      cell("reach_friend_overflow", :friend_hub, ->(g, id) { reach(:both, %i[FRIEND], 2, 100).(g, ref.(id)) },
           size: REACH, check: overflow(max_depth: 2, max_nodes: 100), requires: reachable),
      # Depth-limited, complete within the requested depth.
      cell("reach_knows_depth2", :random, ->(g, id) { reach(:out, %i[KNOWS], 2, 5000).(g, ref.(id)) },
           size: REACH, check: complete(max_depth: 2), requires: reachable),
      # Exact-cap probes (bb topic 148, post 5): the result is exactly full.
      cell("reach_probe_negative", :probe_negative, ->(g, id) { reach(:out, %i[KNOWS], 2, 1).(g, ref.(id)) },
           size: REACH, check: probe(complete: true, stopped_at_depth: nil), requires: reachable),
      cell("reach_probe_positive", :probe_positive, ->(g, id) { reach(:out, %i[KNOWS], 2, 1).(g, ref.(id)) },
           size: REACH, check: probe(complete: false, stopped_at_depth: 1), requires: reachable),
      cell("reach_probe_depth_bound", :probe_positive, ->(g, id) { reach(:out, %i[KNOWS], 1, 1).(g, ref.(id)) },
           size: REACH, check: probe(complete: true, stopped_at_depth: nil), requires: reachable)
    ]
  end
end
