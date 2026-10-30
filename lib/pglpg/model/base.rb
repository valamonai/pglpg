# frozen_string_literal: true

module Pglpg
  module Model
    # Shared by Model::Node and Model::Edge. A model class binds a graph and
    # a schema type; its attributes are the type's properties and the
    # graph's application columns. Models keep the Context they were read
    # or built through, and write through its guarded write API (ADR-0010).
    class Base
      include ActiveModel::API
      include ActiveModel::Attributes
      include ActiveModel::Dirty

      # Attributes are assigned as given: no form coercion ("42" stays a
      # String). The schema checks values on validation.
      class StrictType < ActiveModel::Type::Value
        def cast(value) = value
      end

      STRICT = StrictType.new

      CORE_OWNERS = [Kernel, Object, BasicObject].freeze
      CORE_METHODS = %i[
        class hash freeze frozen? send public_send object_id method methods respond_to? dup clone
        equal? eql? is_a? kind_of? instance_of? nil? itself instance_variable_get instance_variable_set
      ].freeze

      validate :validate_schema

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

        # Anonymous model classes are named after their schema type, so
        # validation messages work for them too.
        def model_name
          return super if name

          @model_name ||= ActiveModel::Name.new(self, nil, schema_type&.name&.to_s || base_class.name.split("::").last)
        end

        # -- internal ----------------------------------------------------------

        # A model of +element+, read through +context+: the model registered
        # for its concrete type, else this one.
        def instantiate(context, element)
          klass = Model.lookup(graph, kind, element_type_name(element)) || self
          klass.allocate.tap { _1.send(:load_element, context, element) }
        end

        # A new record bound to +context+.
        def build(context, attributes)
          new(attributes).tap { _1.instance_variable_set(:@context, context) }
        end

        private

        # A model may extend another model only along the schema's inheritance,
        # checked against the nearest bound ancestor (unbound classes between
        # them still inherit its attributes).
        def check_parent!(graph, schema_type)
          parent = superclass
          parent = parent.superclass while parent < Base && parent.schema_type.nil?
          return unless parent < Base
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

        # Methods of the model classes and ActiveModel, public or private, plus
        # the core Object methods an attribute must never shadow. Other
        # Kernel and Object methods (format, display, ...) may be shadowed.
        def reserved_name?(name)
          [name, :"#{name}="].any? do |m|
            next true if CORE_METHODS.include?(m)
            next false unless base_class.method_defined?(m) || base_class.private_method_defined?(m)

            !CORE_OWNERS.include?(base_class.instance_method(m).owner)
          end
        end
      end

      attr_reader :context, :ref, :created_at, :updated_at

      # Properties stored on the element that this model's type does not
      # declare (a subtype read through a base-type model). Read-only.
      def extra_properties = @extra_properties || {}.freeze

      def id = ref&.id

      def persisted? = !ref.nil? && !destroyed?

      def new_record? = ref.nil?

      def destroyed? = @destroyed == true

      def to_key = persisted? ? [id] : nil

      # The ref as a String; Relation#find accepts it back.
      def to_param = ref&.to_s

      # Validates, then writes through the context's guarded write API: an
      # insert for a new record, else an update of the changed attributes
      # only. Returns false when validation fails. Refusals (WriteRejected,
      # NotTrusted), timeouts and database errors raise; changes are kept on
      # any failure. +writer:+ hands over the context's trusted writer, for
      # trusted-only operations; it never permits assigning a key.
      #
      # Success means the statement succeeded in the caller's transaction.
      # Local state is what was assigned, not a stored snapshot (generated
      # keys and timestamps are unknown until #reload), and a caller's
      # rollback is not tracked: discard or reload the record after one.
      def save(writer: nil)
        target = write_target(writer)
        return false unless valid?

        persist(target)
      end

      # As #save, but raises RecordInvalid when validation fails.
      def save!(writer: nil)
        target = write_target(writer)
        raise RecordInvalid, self unless valid?

        persist(target)
      end

      # Deletes the element through the guarded write API (a node only
      # through the trusted writer). Returns true.
      def destroy(writer: nil)
        raise ArgumentError, "only a persisted record can be destroyed" unless persisted?

        delete_element(write_target(writer))
        @destroyed = true
      end

      # Replaces attributes, timestamps and the dirty baseline from the
      # stored element. Raises RecordNotFound, leaving the record unchanged,
      # when it is missing or no longer visible.
      def reload
        element = ref && context&.find(ref)
        raise RecordNotFound unless element && self.class.matches?(element)

        load_element(context, element)
        self
      end

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
        clear_changes_information
        self
      end

      # The context's interactive writes, or the given writer, which must
      # belong to this record's own context (identity).
      def write_target(writer)
        raise ArgumentError, "#{self.class} has no context; build it with Model.in(ctx).new" unless context
        raise ArgumentError, "#{self.class} was destroyed" if destroyed?
        return context if writer.nil?
        raise ArgumentError, "writer: expects a Pglpg::Writer" unless writer.is_a?(Pglpg::Writer)
        raise ArgumentError, "the writer belongs to another context" unless writer.context.equal?(context)

        writer
      end

      def persist(target)
        if new_record?
          create_element(target, assigned(self.class.property_names), assigned(self.class.column_names))
        elsif changed?
          update_element(target, changes_to(self.class.property_names), changes_to(self.class.column_names))
        end
        changes_applied
        true
      end

      # Non-nil values to insert (nil means absent).
      def assigned(names)
        names.each_with_object({}) do |name, out|
          value = attribute(name.to_s)
          out[name] = value unless value.nil?
        end
      end

      # Changed values to update (nil removes a property).
      def changes_to(names) = names.select { attribute_changed?(_1.to_s) }.to_h { [_1, attribute(_1.to_s)] }

      def element_columns = self.class.send(:element_columns, self.class.graph)

      # Schema checks: property values per the stored type, required
      # properties and columns.
      def validate_schema
        type = schema_type
        self.class.property_names.each do |name|
          prop = type.property_named(name)
          value = attribute(name.to_s)
          if value.nil?
            errors.add(name, :blank) if prop.required? && required_now?(name)
          else
            begin
              prop.encode(value)
            rescue ValidationError
              errors.add(name, :invalid, message: "is not a valid #{prop.type == :list ? "list of #{prop.of}" : prop.type}")
            end
          end
        end
        element_columns.each_value do |column|
          next unless attribute(column.name.to_s).nil?

          blank = new_record? ? column.required? : attribute_changed?(column.name.to_s) && !column.null?
          errors.add(column.name, :blank) if blank
        end
      end

      # A missing required property is an error on insert, and when an
      # update would remove it.
      def required_now?(name) = new_record? || attribute_changed?(name.to_s)
    end

    # save! or create! found validation errors. #record has them.
    class RecordInvalid < Error
      attr_reader :record

      def initialize(record)
        @record = record
        super("validation failed: #{record.errors.full_messages.join(", ")}")
      end
    end
  end
end
