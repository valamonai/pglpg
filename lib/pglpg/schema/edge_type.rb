# frozen_string_literal: true

module Pglpg
  module Schema
    # An edge type: exactly one label (its name), property types, and the
    # node labels its source and target must carry.
    class EdgeType < ElementType
      attr_reader :from, :to, :unique

      def initialize(name, from:, to:, unique: nil, symmetric: false, temporal: false)
        super(name)
        raise SchemaError, "symmetric edge types are planned for 0.2 (#{name})" if symmetric
        raise SchemaError, "temporal edge types are planned for 0.3 (#{name})" if temporal
        raise SchemaError, "unique: must be nil or :pair (#{name})" unless [nil, :pair].include?(unique)

        @from = Schema.check_name!(from, "type")
        @to = Schema.check_name!(to, "type")
        @unique = unique
      end

      # At most one edge of this type between the same source and target.
      def unique_pair? = unique == :pair

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
