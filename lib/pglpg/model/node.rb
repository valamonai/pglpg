# frozen_string_literal: true

module Pglpg
  module Model
    # A model of a node type. A query on it returns nodes of the type and its
    # subtypes; each is built as the model registered for its concrete type,
    # else as the queried model.
    #
    #   class Person < Pglpg::Model::Node
    #     graph Kg, type: :Person
    #     has_many :projects, :out, edge: :WORKS_ON
    #   end
    class Node < Base
      # A declared association: follow +edge_type+ in +direction+ to nodes of
      # +label+, loaded as +model+ (a class, a class name, or nil for the
      # model registered for +label+).
      Association = Data.define(:name, :direction, :edge_type, :label, :model)

      class << self
        def base_class = Model::Node

        # Declares an association, read as a method returning an
        # AssociationRelation:
        #   has_many :projects, :out, edge: :WORKS_ON
        #   has_many :friends, :both, edge: :FRIEND
        #   has_many :team, :in, edge: :WORKS_ON, label: :Employee, model: "Employee"
        # +direction+ is :out or :in for a directed edge type and :both for a
        # symmetric one. The target label defaults to the edge type's other
        # endpoint; +model+ defaults to the model registered for that label.
        def has_many(name, direction, edge:, label: nil, model: nil)
          raise ConfigurationError, "#{self}: declare graph before has_many" unless graph

          name = Schema.check_name!(name, "association")
          edge_type = graph.type.edge_type!(edge)
          owner_labels, target_label = association_ends(edge_type, direction)
          unless owner_labels.any? { |l| graph.type.node_types_with_label(l).any? { _1.label?(schema_type.name) } }
            raise SchemaError, "#{schema_type.name} is not an endpoint of #{edge_type.name} (#{direction})"
          end
          target_label = graph.type.node_type!(label).name if label
          if target_label.nil? && model.nil?
            raise SchemaError, "#{name}: #{edge_type.name} joins two labels; give label: or model:"
          end
          if method_defined?(name) || reserved_name?(name)
            raise SchemaError, "association #{name} clashes with a method of #{self}"
          end

          association = Association.new(name:, direction:, edge_type: edge_type.name, label: target_label, model:)
          own_associations[name] = association
          define_method(name) { association_relation(association) }
          association
        end

        # Associations declared on this model and the models it extends.
        def associations
          inherited = superclass.respond_to?(:associations) ? superclass.associations : {}
          inherited.merge(own_associations)
        end

        # The query variable a relation binds the node to.

        def kind = :node

        # The query variable a relation binds the node to.
        def query_var = :n

        # The pattern a relation starts from.
        def pattern(context) = context.match.node(:n, schema_type.name)

        def matches?(element) = element.label?(schema_type.name)

        def element_type_name(element) = element.key_label

        private

        def own_associations = (@own_associations ||= {})

        def inherited_member_names = associations.keys

        # The owner's possible labels and the target label for +direction+,
        # following the query DSL's rule for symmetric types (ADR-0008).
        def association_ends(edge_type, direction)
          case direction
          when :out, :in
            raise SchemaError, "#{edge_type.name} is symmetric; use :both" if edge_type.symmetric?

            direction == :out ? [[edge_type.from], edge_type.to] : [[edge_type.to], edge_type.from]
          when :both
            raise SchemaError, "#{edge_type.name} is directed; use :out or :in" unless edge_type.symmetric?

            [[edge_type.from, edge_type.to].uniq, (edge_type.from if edge_type.from == edge_type.to)]
          else
            raise ArgumentError, "direction must be :out, :in or :both"
          end
        end

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

      # The association's targets as seen through this record's context,
      # starting from this record (visibility applies to it too).
      def association_relation(association)
        raise ArgumentError, "#{association.name}: save the record first" unless persisted?

        target = association_model(association)
        query = context.match.node(:owner, ref:)
                       .public_send(association.direction, association.edge_type, :n,
                                    association.label || target.schema_type.name, edge: :e)
        edge_model = Model.lookup(self.class.graph, :edge, association.edge_type)
        AssociationRelation.new(target, context, query, edge_model:, cached: (@association_cache || {})[association.name])
      end

      def association_model(association)
        graph = self.class.graph
        model = case association.model
                when nil then Model.lookup(graph, :node, association.label)
                when String, Symbol then resolve_model_name(association.model.to_s)
                else association.model
                end
        unless model.is_a?(Class) && model < Model::Node && model.graph.equal?(graph)
          raise ConfigurationError, "#{self.class}##{association.name}: no node model of graph #{graph.name} " \
                                    "for #{association.label}; give model:"
        end
        if association.label && !graph.type.node_type!(association.label).label?(model.schema_type.name)
          raise ConfigurationError, "#{self.class}##{association.name}: #{association.label} nodes are not #{model}"
        end

        model
      end

      # nil for a name that doesn't resolve, so it reports as a missing model.
      def resolve_model_name(name)
        Object.const_get(name)
      rescue NameError
        nil
      end

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
