# frozen_string_literal: true

module Pglpg
  module Schema
    # A node type: a key label, inherited labels and property types
    # (GQL node types, PG-Schema inheritance).
    class NodeType < ElementType
      attr_reader :parents, :labels, :key, :ancestors

      def initialize(name, extends: [], abstract: false)
        super(name)
        @parents = Array(extends).map { Schema.check_name!(_1, "type") }.freeze
        @abstract = abstract ? true : false
        @own_key = nil
      end

      def abstract? = @abstract

      def key_property(*names, generate: nil, scope: nil)
        raise SchemaError, "#{self.name} declares more than one key" if @own_key

        @own_key = Key.new(names, declared_on: self.name, generate:, scope:)
      end

      def own_key = @own_key

      # Called once the graph type is complete.
      def resolve!(graph_type, stack = [])
        return if @resolved
        raise SchemaError, "inheritance cycle: #{(stack + [name]).join(" < ")}" if stack.include?(name)

        parent_types = parents.map do |p|
          graph_type.node_types.fetch(p) { raise SchemaError, "#{name} extends unknown node type #{p}" }
        end
        parent_types.each { _1.resolve!(graph_type, stack + [name]) }

        @ancestors = parent_types.flat_map { [_1.name, *_1.ancestors] }.uniq.freeze
        @labels = ([name] + @ancestors).map(&:to_s).sort.freeze
        @properties = merge_properties(parent_types)
        @key = resolve_key(parent_types)
        @resolved = true
        freeze
      end

      # True when nodes of this type carry +label+.
      def label?(label) = labels.include?(label.to_s)

      private

      def merge_properties(parent_types)
        merged = {}
        (parent_types.map(&:properties) + [own_properties]).each do |props|
          props.each do |n, prop|
            if merged.key?(n) && !merged[n].same_definition?(prop)
              raise SchemaError, "#{name} inherits conflicting definitions of #{n}"
            end

            merged[n] = prop
          end
        end
        merged.freeze
      end

      def resolve_key(parent_types)
        keys = (parent_types.map(&:key) + [@own_key]).compact.uniq(&:declared_on)
        raise SchemaError, "#{name} has more than one key (#{keys.map(&:declared_on).join(", ")})" if keys.size > 1

        key = keys.first
        return nil unless key

        # Inherited descriptors are already resolved and immutable.
        key.frozen? ? key : key.resolve!(self)
      end
    end
  end
end
