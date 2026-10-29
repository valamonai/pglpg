# frozen_string_literal: true

module Pglpg
  # A graph seen by one viewer. Created by Graph#for; immutable. Every query
  # and write built from it applies the graph's policies for this viewer.
  class Context
    attr_reader :graph, :viewer

    def initialize(graph, viewer)
      @graph = graph
      @viewer = viewer
      freeze
    end

    # Starts a fixed-length pattern query.
    def match = Query.new(self)

    # The visible node or edge behind +ref+, or nil. A hidden element and a
    # missing one look the same.
    def find(ref)
      raise InvalidRef, "expected a Pglpg::Ref" unless ref.is_a?(Ref)

      graph.check_ref!(ref, ref.kind)
      return match.node(:n, ref:).first&.fetch(:n) if ref.node?

      sql = Sql.new(graph.connection)
      e = "e"
      sql << "SELECT to_jsonb(e) AS e FROM " << table_sql(graph.edges_table) << " AS e"
      sql << " JOIN " << table_sql(graph.nodes_table) << " AS s ON s.id = e.source_id AND "
      append_node_visible(sql, "s")
      sql << " JOIN " << table_sql(graph.nodes_table) << " AS t ON t.id = e.target_id AND "
      append_node_visible(sql, "t")
      sql << " WHERE e.id = "
      sql.bind(ref.id, "bigint") << " AND "
      append_edge_visible(sql, e)
      row = read(sql).first
      row && graph.build_edge(JSON.parse(row["e"]))
    end

    # The visible node of +type+ (or a subtype) with the given key, or nil.
    #   ctx.find_node(:Person, uid: "PER-12")
    def find_node(type, **key)
      node_type = graph.type.node_type!(type)
      unless node_type.key && key.keys == [node_type.key.property]
        raise ArgumentError, "#{type} is looked up by #{node_type.key&.property.inspect}"
      end

      match.node(:n, type, **key).first&.fetch(:n)
    end

    # Visible nodes reachable from +from+ within +max_depth+ hops over the
    # edge types in +via+, each with its minimum depth (a Reachability).
    # Hidden nodes and edges are never traversed. The traversal is one
    # statement; +deadline+ (seconds) can only shorten the configured
    # statement timeout. See ADR-0009.
    #   ctx.reachable(from: ref, via: %i[KNOWS], max_depth: 3, max_nodes: 500)
    def reachable(from:, via:, max_depth:, max_nodes:, direction: :out, deadline: nil)
      Reachable.new(self, from:, via:, direction:, max_depth:, max_nodes:, deadline:).call
    end

    def insert_node(type, properties: {}, attrs: {}) = writer.insert_node(type, properties:, attrs:)

    def update_node(ref, properties: {}, attrs: {}) = writer.update_node(ref, properties:, attrs:)

    def insert_edge(type, from:, to:, properties: {}, attrs: {}) = writer.insert_edge(type, from:, to:, properties:, attrs:)

    def update_edge(ref, properties: {}, attrs: {}) = writer.update_edge(ref, properties:, attrs:)

    def delete_edge(ref) = writer.delete_edge(ref)

    # The trusted writer: caller-chosen keys, upserts and node deletion.
    # Raises NotTrusted unless the application's trusted_writer_allowed
    # callable approves this context. It does not bypass validation, the
    # write policy or endpoint checks.
    def trusted_writer
      allowed = graph.trusted_writer_allowed
      raise NotTrusted, "trusted writer not granted" unless allowed.respond_to?(:call) && allowed.call(self) == true

      Writer.new(self, trusted: true)
    end

    def inspect = "#<Pglpg::Context #{graph.name} viewer=#{viewer.inspect}>"

    # -- internal ------------------------------------------------------------

    def table_sql(name) = graph.connection.quote_table_name(name)

    # Appends the visibility condition for the node alias +name+.
    def append_node_visible(sql, name)
      sql << "("
      sql.arel(policy_condition(graph.visibility.node(Arel::Table.new(name), viewer)))
      sql << ")"
    end

    def append_edge_visible(sql, name)
      sql << "("
      sql.arel(policy_condition(graph.visibility.edge(Arel::Table.new(name), viewer)))
      sql << ")"
    end

    # Runs a read under +timeout+ (ms; default: the configured statement
    # timeout). nil leaves the session's timeout as it is. The read always
    # runs in a savepoint, so a timeout (ours or the session's) never leaves
    # the caller's transaction aborted.
    def read(sql, timeout: Pglpg.configuration.statement_timeout)
      graph.with_connection do |c|
        c.transaction(requires_new: true) do
          next c.select_all(sql.to_s, "Pglpg", sql.binds).to_a if timeout.nil?

          previous = c.select_value("SELECT current_setting('statement_timeout')")
          c.select_value("SELECT set_config('statement_timeout', '#{Integer(timeout)}', true)")
          rows = c.select_all(sql.to_s, "Pglpg", sql.binds).to_a
          c.select_value("SELECT set_config('statement_timeout', #{c.quote(previous)}, true)")
          rows
        end
      end
    rescue ActiveRecord::QueryCanceled
      raise QueryTimeout
    end

    private

    def writer = Writer.new(self, trusted: false)

    # A policy must return an Arel condition; anything else fails closed.
    def policy_condition(node)
      return node if node.is_a?(Arel::Nodes::Node) || node.is_a?(Arel::Nodes::SqlLiteral)

      raise ConfigurationError, "policy returned #{node.class}, expected an Arel condition"
    end
  end
end
