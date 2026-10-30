# frozen_string_literal: true

module Pglpg
  module Model
    # A model of a node type. A query on it returns nodes of the type and its
    # subtypes; each is built as the model registered for its concrete type,
    # else as the queried model.
    #
    #   class Person < Pglpg::Model::Node
    #     graph Kg, type: :Person
    #   end
    class Node < Base
      class << self
        def base_class = Model::Node

        def kind = :node

        # The query variable a relation binds the node to.
        def query_var = :n

        # The pattern a relation starts from.
        def pattern(context) = context.match.node(:n, schema_type.name)

        def matches?(element) = element.label?(schema_type.name)

        def element_type_name(element) = element.key_label

        private

        def resolve_type(graph, type) = graph.type.node_type!(type)

        def element_columns(graph) = graph.type.node_columns

        def inherits_type?(type, parent_type) = type == parent_type || type.ancestors.include?(parent_type.name)
      end

      attr_reader :labels

      # The concrete schema type of the stored node, which may be a subtype
      # of the model's type.
      def schema_type = @schema_type || self.class.schema_type

      # The value of the type's key property, or nil.
      def key
        key = schema_type.key or return nil
        self.class.property_names.include?(key.property) ? attribute(key.property.to_s) : extra_properties[key.property]
      end

      private

      def load_identity(element)
        @schema_type = self.class.graph.type.node_type!(element.key_label)
        @labels = element.labels
        self
      end
    end
  end
end
