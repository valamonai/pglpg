# frozen_string_literal: true

module Pglpg
  module Model
    # Shared by Model::Node and Model::Edge. A model class binds a graph and
    # a schema type; its attributes are the type's properties and the
    # graph's application columns. Loaded models keep the Context they were
    # read through.
    class Base
      include ActiveModel::API
      include ActiveModel::Attributes

      # Attributes are assigned as given: no form coercion ("42" stays a
      # String). The schema checks values when they are written.
      class StrictType < ActiveModel::Type::Value
        def cast(value) = value
      end

      STRICT = StrictType.new

      CORE_OWNERS = [Kernel, Object, BasicObject].freeze
      CORE_METHODS = %i[
        class hash freeze frozen? send public_send object_id method methods respond_to? dup clone
        equal? eql? is_a? kind_of? instance_of? nil? itself instance_variable_get instance_variable_set
      ].freeze

      class << self
        # Binds the model to a graph and a schema type:
        #   graph Kg, type: :Person
        # Without arguments, returns the bound graph.
        def graph(graph = nil, type: nil)
          return @graph if graph.nil? && type.nil?
          raise ConfigurationError, "#{self} is already bound to graph #{@graph.name}" if @graph
          raise ArgumentError, "graph must be a Pglpg::Graph" unless graph.is_a?(Pglpg::Graph)

          schema_type = resolve_type(graph, type)
          check_parent!(graph, schema_type)
          property_names = schema_type.properties.keys
          column_names = element_columns(graph).keys
          check_attribute_names!(schema_type, property_names, column_names)

          property_names.each { attribute(_1, STRICT) }
          column_names.each { attribute(_1, STRICT) }
          @graph = graph
          @schema_type = schema_type
          @property_names = property_names.freeze
          @column_names = column_names.freeze
          Model.register(graph, kind, schema_type.name, self)
          graph
        end

        attr_reader :schema_type, :property_names, :column_names

        # The model's elements as seen through +context+: a Relation.
        def in(context)
          raise ConfigurationError, "#{self} is not bound to a graph; declare graph Kg, type: ..." unless @graph
          raise ArgumentError, "expected a Pglpg::Context" unless context.is_a?(Pglpg::Context)
          raise ArgumentError, "the context belongs to graph #{context.graph.name}, not #{@graph.name}" unless context.graph.equal?(@graph)

          Relation.new(self, context)
        end

        # -- internal ----------------------------------------------------------

        # A model of +element+, read through +context+: the model registered
        # for its concrete type, else this one.
        def instantiate(context, element)
          klass = Model.lookup(graph, kind, element_type_name(element)) || self
          klass.allocate.tap { _1.send(:load_element, context, element) }
        end

        private

        # A model may extend another model only along the schema's inheritance.
        def check_parent!(graph, schema_type)
          parent = superclass
          return unless parent.respond_to?(:schema_type) && parent.schema_type
          return if parent.graph.equal?(graph) && inherits_type?(schema_type, parent.schema_type)

          raise SchemaError, "#{self} (#{schema_type.name}) cannot extend #{parent} (#{parent.schema_type.name})"
        end

        def check_attribute_names!(schema_type, property_names, column_names)
          clashes = property_names & column_names
          raise SchemaError, "#{schema_type.name} has properties named like columns: #{clashes.join(", ")}" if clashes.any?

          (property_names + column_names).each do |name|
            next unless reserved_name?(name)

            raise SchemaError, "#{schema_type.name}.#{name} clashes with a method of #{base_class}"
          end
        end

        # Methods of the model classes and ActiveModel, plus the core Object
        # methods an attribute must never shadow.
        def reserved_name?(name)
          [name, :"#{name}="].any? do |m|
            next true if CORE_METHODS.include?(m)

            base_class.public_method_defined?(m) && !CORE_OWNERS.include?(base_class.instance_method(m).owner)
          end
        end
      end

      attr_reader :context, :ref, :created_at, :updated_at

      # Properties stored on the element that this model's type does not
      # declare (a subtype read through a base-type model). Read-only.
      def extra_properties = @extra_properties || {}.freeze

      def id = ref&.id

      def persisted? = !ref.nil?

      def new_record? = ref.nil?

      def to_key = persisted? ? [id] : nil

      # The ref as a String; Relation#find accepts it back.
      def to_param = ref&.to_s

      def ==(other) = other.is_a?(self.class.base_class) && !ref.nil? && other.ref == ref

      alias eql? ==

      def hash = ref ? ref.hash : super

      def inspect
        attrs = attributes.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
        "#<#{self.class.name || self.class.base_class.name} #{ref || "new"} #{attrs}>"
      end

      private

      def load_element(context, element)
        @attributes = self.class._default_attributes.deep_dup
        @context = context
        @ref = element.ref
        @created_at = element.created_at
        @updated_at = element.updated_at
        properties = element.properties
        self.class.property_names.each { @attributes.write_from_database(_1.to_s, properties[_1]) }
        self.class.column_names.each { @attributes.write_from_database(_1.to_s, element.attrs[_1]) }
        @extra_properties = properties.except(*self.class.property_names).freeze
        load_identity(element)
      end
    end
  end
end
