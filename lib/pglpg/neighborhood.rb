# frozen_string_literal: true

module Pglpg
  Neighborhood = Data.define(:nodes, :edges, :nodes_truncated, :edges_truncated) do
    def nodes_truncated? = nodes_truncated
    def edges_truncated? = edges_truncated
  end

  # Reuses Reachable's bounded BFS, then selects the induced edges before
  # hydrating either result. Probe nodes are excluded from the selected set.
  class NeighborhoodQuery < Reachable
    def initialize(context, max_edges:, **options)
      unless max_edges.is_a?(Integer) && max_edges.between?(0, Pglpg.configuration.max_rows)
        raise ArgumentError, "max_edges must be an Integer from 0 to max_rows"
      end

      @max_edges = max_edges
      super(context, **options)
    end

    def call
      row = @context.read(compile, timeout: @timeout).fetch(0)
      nodes = JSON.parse(row.fetch("nodes")).map { |data, depth| [@graph.build_node(data), depth].freeze }
      edges = JSON.parse(row.fetch("edges")).map { @graph.build_edge(_1) }
      Neighborhood.new(nodes: nodes.freeze, edges: edges.freeze,
                       nodes_truncated: row.fetch("nodes_truncated"), edges_truncated: row.fetch("edges_truncated"))
    end

    def compile
      sql = Sql.new(@graph.connection)
      append_bfs(sql)
      sql << ", candidates AS MATERIALIZED (SELECT b.depth, u.id, u.ord FROM bfs AS b"
      sql << " CROSS JOIN LATERAL unnest(b.frontier) WITH ORDINALITY AS u(id, ord))"
      sql << ", selected AS MATERIALIZED (SELECT id, depth FROM candidates ORDER BY depth, ord LIMIT "
      sql.bind(@max_nodes, "bigint") << ")"
      sql << ", selected_rows AS MATERIALIZED (SELECT n.* FROM selected AS s JOIN "
      sql << @context.table_sql(@graph.nodes_table) << " AS n ON n.id = s.id AND "
      @context.append_node_visible(sql, "n")
      sql << ")"
      append_edges(sql)
      sql << " SELECT COALESCE((SELECT jsonb_agg(jsonb_build_array(to_jsonb(n), s.depth) ORDER BY s.depth, s.id)"
      sql << " FROM selected AS s JOIN selected_rows AS n ON n.id = s.id), '[]') AS nodes,"
      sql << " COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM"
      sql << " (SELECT * FROM edge_probe ORDER BY id LIMIT "
      sql.bind(@max_edges, "bigint") << ") AS e), '[]') AS edges,"
      sql << " (SELECT count(*) FROM candidates) > "
      sql.bind(@max_nodes, "bigint") << " AS nodes_truncated,"
      sql << " (SELECT count(*) FROM edge_probe) > "
      sql.bind(@max_edges, "bigint") << " AS edges_truncated"
    end

    private

    def neighbor_budget = @max_nodes - 1

    def edge_types!(via, direction)
      raise ArgumentError, "direction must be :out, :in or :both" unless DIRECTIONS.include?(direction)

      types = (via.is_a?(Array) ? via : [via]).map { @graph.type.edge_type!(_1).name }.uniq
      raise ArgumentError, "via needs at least one edge type" if types.empty?

      types.freeze
    end

    def append_steps(sql)
      outgoing = @types.select { @direction != :in || @graph.type.edge_type!(_1).symmetric? }
      incoming = @types.select { @direction != :out || @graph.type.edge_type!(_1).symmetric? }
      steps = [[outgoing, "source_id", "target_id"], [incoming, "target_id", "source_id"]]
      steps.reject { |types, _, _| types.empty? }.each_with_index do |(types, near, far), index|
        sql << " UNION ALL " if index.positive?
        append_step(sql, "e#{index}", near, far, types)
      end
    end

    def append_edges(sql)
      nodes = "selected_rows"
      sql << ", edge_probe AS MATERIALIZED (SELECT e.* FROM " << @context.table_sql(@graph.edges_table) << " AS e"
      sql << " JOIN selected AS s ON s.id = e.source_id JOIN selected AS t ON t.id = e.target_id"
      sql << " JOIN " << nodes << " AS sn ON sn.id = s.id AND "
      @context.append_node_visible(sql, "sn")
      sql << " JOIN " << nodes << " AS tn ON tn.id = t.id AND "
      @context.append_node_visible(sql, "tn")
      sql << " WHERE e.type = ANY("
      sql.bind_text_array(@types) << ") AND "
      @context.append_edge_visible(sql, "e")
      @context.append_temporal(sql, "e", @types.map { @graph.type.edge_type!(_1) })
      sql << " ORDER BY e.id LIMIT "
      sql.bind(@max_edges + 1, "bigint") << ")"
    end
  end
end
