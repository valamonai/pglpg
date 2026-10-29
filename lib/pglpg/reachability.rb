# frozen_string_literal: true

module Pglpg
  # The result of Context#reachable: visible nodes with their minimum depth,
  # ordered by depth, then id. +complete+ is false when more visible nodes
  # are reachable within max_depth than were returned; +stopped_at_depth+ is
  # then the depth of the last returned node, and nil otherwise.
  Reachability = Data.define(:nodes, :complete, :stopped_at_depth) do
    def complete? = complete
  end

  # Compiles and runs Context#reachable as one recursive CTE whose rows are
  # whole BFS levels (ADR-0009). Each level excludes visited nodes and is
  # capped at remaining + 1, which is 1 when the result is exactly full: that
  # one row is the probe that decides completeness.
  class Reachable
    DIRECTIONS = %i[out in both].freeze

    def initialize(context, from:, via:, direction:, max_depth:, max_nodes:, deadline:)
      @context = context
      @graph = context.graph
      @from = @graph.check_ref!(from, :node)
      @types = edge_types!(via, direction)
      @direction = direction
      @max_depth = positive_integer!(max_depth, "max_depth")
      @max_nodes = positive_integer!(max_nodes, "max_nodes")
      raise ArgumentError, "max_nodes exceeds max_rows (#{max_rows})" if @max_nodes > max_rows

      @timeout = timeout_ms(deadline)
      freeze
    end

    def call
      rows = @context.read(compile, timeout: @timeout).map { [@graph.ref(:node, _1["id"].to_i), _1["depth"].to_i].freeze }
      if rows.size > @max_nodes
        nodes = rows.first(@max_nodes)
        Reachability.new(nodes: nodes.freeze, complete: false, stopped_at_depth: nodes.last[1])
      else
        Reachability.new(nodes: rows.freeze, complete: true, stopped_at_depth: nil)
      end
    end

    def compile
      sql = Sql.new(@graph.connection)
      nodes = @context.table_sql(@graph.nodes_table)
      sql << "WITH RECURSIVE bfs(depth, frontier, visited) AS ("
      sql << "SELECT 0, ARRAY[s.id], ARRAY[s.id] FROM " << nodes << " AS s WHERE s.id = "
      sql.bind(@from.id, "bigint") << " AND "
      @context.append_node_visible(sql, "s")
      sql << " UNION ALL SELECT b.depth + 1, nxt.ids, b.visited || nxt.ids FROM bfs AS b"
      sql << " CROSS JOIN LATERAL (SELECT ARRAY(SELECT DISTINCT n.id FROM ("
      append_steps(sql)
      sql << ") AS x JOIN " << nodes << " AS n ON n.id = x.far AND "
      @context.append_node_visible(sql, "n")
      sql << " WHERE n.id <> ALL(b.visited) ORDER BY n.id LIMIT "
      # remaining + 1, where remaining = max_nodes - (cardinality(visited) - 1)
      sql.bind(@max_nodes, "int") << " - cardinality(b.visited) + 2) AS ids"
      # Without OFFSET 0 the subquery is inlined into both references to
      # nxt.ids and each level is computed twice.
      sql << " OFFSET 0) AS nxt WHERE b.depth < "
      sql.bind(@max_depth, "int") << " AND cardinality(b.frontier) > 0 AND cardinality(b.visited) - 1 <= "
      sql.bind(@max_nodes, "int") << ")"
      sql << " SELECT b.depth, u.id FROM bfs AS b CROSS JOIN LATERAL unnest(b.frontier) WITH ORDINALITY AS u(id, ord)"
      sql << " WHERE b.depth > 0 ORDER BY b.depth, u.ord"
    end

    private

    def max_rows = Pglpg.configuration.max_rows

    # The far ends of visible edges leaving the frontier, as column "far". A
    # symmetric type is followed from both stored columns, as two branches
    # that each use a traversal index.
    def append_steps(sql)
      case @direction
      when :out then append_step(sql, "e0", "source_id", "target_id")
      when :in then append_step(sql, "e0", "target_id", "source_id")
      else
        append_step(sql, "e0", "source_id", "target_id")
        sql << " UNION ALL "
        append_step(sql, "e1", "target_id", "source_id")
      end
    end

    def append_step(sql, e, near, far)
      sql << "SELECT " << e << "." << far << " AS far FROM " << @context.table_sql(@graph.edges_table) << " AS " << e
      sql << " WHERE " << e << "." << near << " = ANY(b.frontier) AND " << e << ".type = ANY("
      sql.bind_text_array(@types) << ") AND "
      @context.append_edge_visible(sql, e)
    end

    def edge_types!(via, direction)
      raise ArgumentError, "direction must be :out, :in or :both" unless DIRECTIONS.include?(direction)

      types = (via.is_a?(Array) ? via : [via]).map { @graph.type.edge_type!(_1) }.uniq
      raise ArgumentError, "via needs at least one edge type" if types.empty?

      types.each do |t|
        if t.symmetric? && direction != :both
          raise ArgumentError, "#{t.name} is symmetric; use direction: :both"
        elsif !t.symmetric? && direction == :both
          raise ArgumentError, "#{t.name} is directed; use direction: :out or :in"
        end
      end
      types.map(&:name).freeze
    end

    def positive_integer!(value, name)
      raise ArgumentError, "#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      value
    end

    # The statement timeout in milliseconds, or nil to leave the session's.
    # A configured timeout caps the deadline; nil or 0 configures no cap.
    def timeout_ms(deadline)
      configured = Pglpg.configuration.statement_timeout
      cap = Integer(configured) if configured && Integer(configured).positive?
      return cap if deadline.nil?

      unless deadline.is_a?(Numeric) && deadline.real? && deadline.finite? && deadline.positive?
        raise ArgumentError, "deadline must be a positive number of seconds"
      end

      # Rounded up, so a positive deadline never becomes 0 (no timeout). The
      # round(6) drops float noise such as 0.3 * 1000 = 300.00000000000006.
      ms = [(deadline * 1000).round(6).ceil, 1].max
      cap ? [cap, ms].min : ms
    end
  end
end
