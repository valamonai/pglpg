# frozen_string_literal: true

require "securerandom"

module Pglpg
  module Schema
    # One required, immutable property tuple. Shared by schema validation,
    # index generation and ON CONFLICT so their equality cannot diverge.
    class Key
      TYPES = %i[string integer boolean enum].freeze
      DEFAULT_GENERATOR = ->(_type) { SecureRandom.uuid }

      attr_reader :properties, :declared_on, :scope, :generator

      def initialize(names, declared_on:, generate: nil, scope: nil, generation: true)
        @names = names.map { Schema.check_name!(_1, "key property") }.freeze
        raise SchemaError, "a key needs distinct properties" if @names.empty? || @names.uniq != @names
        raise SchemaError, "scope needs a single key property" if scope && @names.size != 1
        raise SchemaError, "key generator must respond to call" if generate && !generate.respond_to?(:call)
        raise SchemaError, "composite keys cannot have a generator" if generate && @names.size != 1

        @scope = scope && Schema.check_name!(scope, "key scope")
        @properties = [@scope, *@names].compact.freeze
        raise SchemaError, "scope must differ from key property" if @properties.uniq != @properties
        raise SchemaError, "key has too many components" if @properties.size > 32

        @declared_on = declared_on
        @generator = generate
        @generation = generation
      end

      # Legacy single/scoped keys expose their generated property.
      def property = @names.size == 1 ? @names.first : nil

      def generated? = !generator.nil?

      def generate(type) = generator.call(type)

      def resolve!(type)
        properties.each do |name|
          prop = type.properties[name]
          raise SchemaError, "key #{declared_on}.#{name} is not a declared property" unless prop
          unless prop.required? && TYPES.include?(prop.type)
            raise SchemaError, "key #{declared_on}.#{name} must be a required #{TYPES.join('/')} property"
          end
        end
        if scope && properties.any? { type.properties.fetch(_1).type != :string }
          raise SchemaError, "scoped keys require string properties"
        end
        if @generator && type.properties.fetch(property).type != :string
          raise SchemaError, "only single string keys can have generators"
        end
        if @generation && property && type.properties.fetch(property).type == :string
          @generator ||= DEFAULT_GENERATOR
        end
        @types = properties.to_h { [_1, type.properties.fetch(_1).type] }.freeze
        freeze
      end

      def json_component?(name) = %i[integer boolean].include?(@types.fetch(name))

      def expressions(connection)
        properties.map do |name|
          operator = json_component?(name) ? "->" : "->>"
          "(properties#{operator}#{connection.quote(name.to_s)})"
        end
      end

      # Lookups accept literal complete keys, never query operators/arrays/nil.
      def validate_values!(type, values)
        unless values.keys.sort == properties.sort
          raise ArgumentError, "#{declared_on} requires the complete key #{properties.inspect}"
        end
        properties.each do |name|
          raise ValidationError, "#{declared_on}.#{name} is required" if values[name].nil?

          type.properties.fetch(name).encode(values[name])
        end
      end
    end
  end
end
