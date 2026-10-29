# frozen_string_literal: true

require "json"

module Pglpg
  # A property graph: its graph type, its storage, and the policies that
  # guard it. Every read and write starts from #for.
  #
  #   Kg = Pglpg::Graph.define(:kg) do
  #     node_column :classification, :integer, null: false
  #     node :Person do
  #       property :uid, :string, required: true
  #       key :uid
  #     end
  #   end
  #   Kg.for(viewer: current_viewer).match.node(:p, :Person).to_a
  class Graph
    attr_reader :name, :type, :storage

    def self.define(name, nodes_table: nil, edges_table: nil, visibility: nil, write_policy: nil,
                    trusted_writer_allowed: nil, connection_class: nil, &block)
      type = Schema::GraphType.new
      Schema::Builder.new(type).instance_eval(&block) if block
      type.resolve!
      new(name, type, nodes_table: nodes_table || "#{name}_nodes", edges_table: edges_table || "#{name}_edges",
                      visibility:, write_policy:, trusted_writer_allowed:, connection_class:)
    end

    def initialize(name, type, nodes_table:, edges_table:, visibility:, write_policy:, trusted_writer_allowed:,
                   connection_class:)
      @name = Schema.check_name!(name, "graph")
      @type = type
      @storage = Storage.new(self, nodes_table:, edges_table:)
      @visibility = visibility
      @write_policy = write_policy
      @trusted_writer_allowed = trusted_writer_allowed
      @connection_class = connection_class
      freeze
    end

    # The only entry point for queries and writes. The returned context is
    # immutable and carries the viewer to everything built from it.
    def for(viewer:)
      Context.new(self, viewer)
    end

    def ref(kind, id) = Ref.new(graph: name, kind:, id:)

    # Parses "graph:kind:id" as produced by Ref#to_s.
    def parse_ref(string)
      graph, kind, id = string.to_s.split(":", 3)
      raise InvalidRef, "not a ref of graph #{name}" unless graph == name.to_s && %w[node edge].include?(kind)

      ref(kind, Integer(id, 10))
    rescue ArgumentError, TypeError
      raise InvalidRef, "malformed ref"
    end

    # Raises unless +ref+ is a Ref of this graph and of the given kind.
    def check_ref!(ref, kind)
      raise InvalidRef, "expected a Pglpg::Ref" unless ref.is_a?(Ref)
      raise InvalidRef, "ref belongs to graph #{ref.graph}, not #{name}" unless ref.graph == name
      raise InvalidRef, "expected a #{kind} ref" unless ref.kind == kind

      ref
    end

    def visibility
      @visibility || Pglpg.configuration.visibility ||
        raise(ConfigurationError, "no visibility policy configured for graph #{name}")
    end

    def write_policy
      @write_policy || Pglpg.configuration.write_policy ||
        raise(ConfigurationError, "no write policy configured for graph #{name}")
    end

    def trusted_writer_allowed = @trusted_writer_allowed || Pglpg.configuration.trusted_writer_allowed

    def connection_class = @connection_class || Pglpg.configuration.connection_class || ActiveRecord::Base

    def with_connection(&) = connection_class.with_connection(&)

    def connection
      connection_class.respond_to?(:lease_connection) ? connection_class.lease_connection : connection_class.connection
    end

    def nodes_table = storage.nodes_table

    def edges_table = storage.edges_table

    def inspect = "#<Pglpg::Graph #{name}>"

    # Builds a Node from the to_jsonb() of a nodes row.
    def build_node(row)
      node_type = type.node_types[row["key_label"].to_sym]
      Node.new(
        ref: ref(:node, row["id"]), key_label: row["key_label"].to_sym,
        labels: row["labels"].map(&:to_sym).freeze,
        properties: node_type ? node_type.decode_properties(row["properties"]) : row["properties"].transform_keys(&:to_sym).freeze,
        attrs: decode_attrs(type.node_columns, row),
        created_at: Time.iso8601(row["created_at"]), updated_at: Time.iso8601(row["updated_at"])
      )
    end

    # Builds an Edge from the to_jsonb() of an edges row.
    def build_edge(row)
      edge_type = type.edge_types[row["type"].to_sym]
      Edge.new(
        ref: ref(:edge, row["id"]), type: row["type"].to_sym,
        source: ref(:node, row["source_id"]), target: ref(:node, row["target_id"]),
        properties: edge_type ? edge_type.decode_properties(row["properties"]) : row["properties"].transform_keys(&:to_sym).freeze,
        attrs: decode_attrs(type.edge_columns, row),
        created_at: Time.iso8601(row["created_at"]), updated_at: Time.iso8601(row["updated_at"]),
        symmetric: edge_type&.symmetric? || false
      )
    end

    private

    def decode_attrs(columns, row)
      columns.each_value.to_h do |c|
        value = row[c.name.to_s]
        cast = begin
          ActiveModel::Type.lookup(c.type).cast(value)
        rescue ArgumentError
          value
        end
        [c.name, cast]
      end.freeze
    end
  end
end
