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

      # Endpoints of a new record: a node Ref or a node model. They can't
      # change once the edge is stored.
      def source=(node)
        @source = endpoint(node)
      end

      def target=(node)
        @target = endpoint(node)
      end

      validate :validate_endpoints

      private

      def load_identity(element)
        @source = element.source
        @target = element.target
        self
      end

      def endpoint(node)
        raise ArgumentError, "the endpoints of a stored edge can't change" unless new_record?
        return nil if node.nil?

        ref = node.is_a?(Model::Node) ? node.ref : node
        raise ArgumentError, "the endpoint is not stored yet" if ref.nil?

        self.class.graph.check_ref!(ref, :node)
      end

      # A symmetric edge is stored in canonical order, so the record takes it.
      def create_element(writer, properties, attrs)
        @ref = writer.insert_edge(schema_type.name, from: source, to: target, properties:, attrs:)
        @source, @target = @target, @source if symmetric? && @source.id > @target.id
      end

      def update_element(writer, properties, attrs)
        writer.update_edge(ref, properties:, attrs:)
      end

      def delete_element(writer) = writer.delete_edge(ref)

      def validate_endpoints
        return unless new_record?

        errors.add(:source, :blank) if source.nil?
        errors.add(:target, :blank) if target.nil?
      end
    end
  end
end
