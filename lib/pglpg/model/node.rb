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

      validate :validate_node

      private

      def load_identity(element)
        @schema_type = self.class.graph.type.node_type!(element.key_label)
        @labels = element.labels
        self
      end

      # Labels follow from the type, so they are known without a reload.
      def create_element(target, properties, attrs)
        @ref = target.insert_node(schema_type.name, properties:, attrs:)
        @labels = schema_type.labels.map(&:to_sym).freeze
      end

      def update_element(target, properties, attrs)
        target.update_node(ref, properties:, attrs:)
      end

      def delete_element(target)
        raise NotTrusted, "destroying a node needs the trusted writer" unless target.is_a?(Pglpg::Writer)

        target.delete_node(ref)
      end

      def key_property = schema_type.key&.property

      # The generated key is not required on insert.
      def required_now?(name) = new_record? ? name != key_property : super

      # Keys are generated on insert and never change (ADR-0005, ADR-0010).
      def validate_node
        errors.add(:base, "#{schema_type.name} is abstract") if new_record? && schema_type.abstract?
        key = key_property
        return unless key && self.class.property_names.include?(key)

        if new_record?
          errors.add(key, "is generated and cannot be assigned") unless attribute(key.to_s).nil?
        elsif attribute_changed?(key.to_s)
          errors.add(key, "cannot be changed")
        end
      end
    end
  end
end
