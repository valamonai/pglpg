# frozen_string_literal: true

module Pglpg
  module Schema
    # The schema of one graph: its node types, edge types and application
    # columns. Built by Builder and frozen once resolved.
    class GraphType
      attr_reader :node_types, :edge_types, :node_columns, :edge_columns

      def initialize
        @node_types = {}
        @edge_types = {}
        @node_columns = {}
        @edge_columns = {}
      end

      def node_type!(name)
        node_types.fetch(name.to_sym) { raise ArgumentError, "unknown node type #{name.inspect}" }
      end

      def edge_type!(name)
        edge_types.fetch(name.to_sym) { raise ArgumentError, "unknown edge type #{name.inspect}" }
      end

      # Concrete node types that carry +label+ (the type itself and its subtypes).
      def node_types_with_label(label)
        node_types.values.select { _1.label?(label) }
      end

      def resolve!
        node_types.each_value { _1.resolve!(self) }
        edge_types.each_value { _1.resolve!(self) }
        [node_types, edge_types, node_columns, edge_columns].each(&:freeze)
        freeze
      end
    end

    # The block DSL of Pglpg::Graph.define.
    class Builder
      def initialize(graph_type)
        @graph_type = graph_type
      end

      def node(name, extends: [], abstract: false, &block)
        type = NodeType.new(name, extends:, abstract:)
        raise SchemaError, "type #{type.name} is declared twice" if declared?(type.name)

        NodeBuilder.new(type).instance_eval(&block) if block
        @graph_type.node_types[type.name] = type
      end

      def edge(name, from:, to:, unique: nil, symmetric: false, temporal: false, &block)
        type = EdgeType.new(name, from:, to:, unique:, symmetric:, temporal:)
        raise SchemaError, "type #{type.name} is declared twice" if declared?(type.name)

        ElementBuilder.new(type).instance_eval(&block) if block
        @graph_type.edge_types[type.name] = type
      end

      def node_column(name, type, **options) = add_column(@graph_type.node_columns, name, type, options)

      def edge_column(name, type, **options) = add_column(@graph_type.edge_columns, name, type, options)

      # Adds the same application column to both tables.
      def column(name, type, **options)
        node_column(name, type, **options)
        edge_column(name, type, **options)
      end

      private

      def declared?(name) = @graph_type.node_types.key?(name) || @graph_type.edge_types.key?(name)

      def add_column(columns, name, type, options)
        column = Column.new(name, type, **options)
        raise SchemaError, "column #{column.name} is declared twice" if columns.key?(column.name)

        columns[column.name] = column
      end
    end

    class ElementBuilder
      def initialize(type)
        @type = type
      end

      def property(name, type, required: false, values: nil, of: nil)
        @type.property(name, type, required:, values:, of:)
      end
    end

    class NodeBuilder < ElementBuilder
      # Declares an exclusive key. Interactive inserts get a value from
      # +generate+ (default: a random UUID); callers never choose it.
      def key(name, generate: nil)
        @type.key_property(name, generate:)
      end
    end
  end
end
