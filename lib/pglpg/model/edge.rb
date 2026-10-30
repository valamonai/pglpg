# frozen_string_literal: true

module Pglpg
  module Model
    # A model of an edge type. For a symmetric type, source and target are
    # the stored (canonical) endpoints and carry no direction.
    #
    #   class WorksOn < Pglpg::Model::Edge
    #     graph Kg, type: :WORKS_ON
    #   end
    class Edge < Base
      class << self
        def base_class = Model::Edge

        def kind = :edge

        def query_var = :e

        # Symmetric edges bind once per orientation, so the relation returns
        # each edge once (distinct).
        def pattern(context)
          q = context.match.node(:s)
          q = schema_type.symmetric? ? q.both(schema_type.name, :t, edge: :e) : q.out(schema_type.name, :t, edge: :e)
          q.return(:e).distinct
        end

        def matches?(element) = element.type == schema_type.name

        def element_type_name(element) = element.type

        private

        def resolve_type(graph, type) = graph.type.edge_type!(type)

        def element_columns(graph) = graph.type.edge_columns

        def inherits_type?(type, parent_type) = type == parent_type
      end

      attr_reader :source, :target

      def schema_type = self.class.schema_type

      def symmetric? = schema_type.symmetric?

      # The endpoint opposite +ref+ (the same node for a self-loop).
      def other(ref)
        return target if ref == source
        return source if ref == target

        raise ArgumentError, "#{ref} is not an endpoint of #{self.ref}"
      end

      private

      def load_identity(element)
        @source = element.source
        @target = element.target
        self
      end
    end
  end
end
