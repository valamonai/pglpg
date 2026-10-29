# frozen_string_literal: true

module Pglpg
  module Schema
    # An edge type: exactly one label (its name), property types, and the
    # node labels its source and target must carry.
    #
    # A symmetric edge type is undirected (ADR-0008): each edge is stored
    # once with source_id < target_id (<= with allow_self_loops), and one
    # endpoint carries +from+ and the other +to+, in either order.
    class EdgeType < ElementType
      attr_reader :from, :to, :unique

      def initialize(name, from:, to:, unique: nil, symmetric: false, allow_self_loops: false, temporal: false)
        super(name)
        raise SchemaError, "temporal edge types are planned for 0.3 (#{name})" if temporal
        raise SchemaError, "unique: must be nil or :pair (#{name})" unless [nil, :pair].include?(unique)
        raise SchemaError, "allow_self_loops: needs symmetric: true (#{name})" if allow_self_loops && !symmetric

        @from = Schema.check_name!(from, "type")
        @to = Schema.check_name!(to, "type")
        @unique = unique
        @symmetric = symmetric == true
        @allow_self_loops = allow_self_loops == true
      end

      # At most one edge of this type between the same source and target
      # (the same unordered pair, for a symmetric type).
      def unique_pair? = unique == :pair

      def symmetric? = @symmetric

      def allow_self_loops? = @allow_self_loops

      def resolve!(graph_type)
        [from, to].each do |label|
          next if graph_type.node_types.key?(label)

          raise SchemaError, "edge #{name} refers to unknown node type #{label}"
        end
        @properties = own_properties.dup.freeze
        freeze
      end
    end
  end
end
