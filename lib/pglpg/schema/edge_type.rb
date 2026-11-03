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
      attr_reader :from, :to, :unique, :key, :pair_key

      def initialize(name, from:, to:, unique: nil, symmetric: false, allow_self_loops: false, temporal: false, open: false)
        super(name, open:)
        raise SchemaError, "temporal: must be true or false" unless [true, false].include?(temporal)
        @temporal = temporal
        unless unique.nil? || unique == :pair || (unique.is_a?(Array) && !unique.empty?)
          raise SchemaError, "unique: must be nil, :pair or a nonempty property list (#{name})"
        end
        @pair_key = Key.new(unique, declared_on: self.name, generation: false) if unique.is_a?(Array)
        raise SchemaError, "pair uniqueness has too many components" if @pair_key && @pair_key.properties.size > 30
        raise SchemaError, "allow_self_loops: needs symmetric: true (#{name})" if allow_self_loops && !symmetric

        @from = Schema.check_name!(from, "type")
        @to = Schema.check_name!(to, "type")
        @unique = unique.is_a?(Array) ? unique.dup.freeze : unique
        @symmetric = symmetric == true
        @allow_self_loops = allow_self_loops == true
      end

      # At most one edge of this type between the same source and target
      # (the same unordered pair, for a symmetric type).
      def unique_pair? = unique == :pair

      def unique_pair_properties = pair_key ? pair_key.properties : [].freeze

      def unique_tuple? = unique_pair? || !pair_key.nil?

      def immutable_properties = ((key&.properties || []) + unique_pair_properties).uniq

      def key_property(*names, generate: nil)
        raise SchemaError, "#{name} declares more than one key" if @key

        @key = Key.new(names, declared_on: name, generate:)
      end

      def temporal? = @temporal

      def symmetric? = @symmetric

      def allow_self_loops? = @allow_self_loops

      def resolve!(graph_type)
        [from, to].each do |label|
          next if graph_type.node_types.key?(label)

          raise SchemaError, "edge #{name} refers to unknown node type #{label}"
        end
        @properties = own_properties.dup.freeze
        resolve_open!(graph_type.edge_columns)
        @key&.resolve!(self)
        @pair_key&.resolve!(self)
        freeze
      end
    end
  end
end
