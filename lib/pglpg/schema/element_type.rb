# frozen_string_literal: true

module Pglpg
  module Schema
    NAME_FORMAT = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    def self.check_name!(name, what)
      raise SchemaError, "invalid #{what} name #{name.inspect}" unless name.to_s.match?(NAME_FORMAT)

      name.to_sym
    end

    # Shared by node and edge types: declared properties. Types are closed:
    # a property that is not declared is rejected.
    class ElementType
      attr_reader :name

      def initialize(name)
        @name = Schema.check_name!(name, "type")
        @own_properties = {}
      end

      def property(name, type, required: false, values: nil, of: nil)
        name = Schema.check_name!(name, "property")
        raise SchemaError, "#{self.name}.#{name} is declared twice" if @own_properties.key?(name)

        @own_properties[name] = Property.new(name, type, required:, values:, of:)
      end

      def own_properties = @own_properties

      # All properties, inherited ones included.
      def properties = @properties || @own_properties

      def property_named(name) = properties[name.to_sym]

      def required_properties = properties.values.select(&:required?)

      # Validates +props+ and returns the JSON hash to store. nil values are
      # dropped (null means absent). With +partial+, required properties may be
      # missing but may not be set to nil.
      def encode_properties(props, partial: false)
        props = (props || {}).transform_keys(&:to_sym)
        unknown = props.keys - properties.keys
        raise ValidationError, "#{name} has no propert#{unknown.size == 1 ? "y" : "ies"} #{unknown.join(", ")}" if unknown.any?

        required_properties.each do |p|
          next if partial && !props.key?(p.name)
          raise ValidationError, "#{name}.#{p.name} is required" if props[p.name].nil?
        end
        props.each_with_object({}) do |(k, v), out|
          encoded = properties.fetch(k).encode(v)
          out[k.to_s] = encoded unless encoded.nil?
        end
      end

      def decode_properties(json)
        (json || {}).each_with_object({}) do |(k, v), out|
          prop = properties[k.to_sym]
          out[k.to_sym] = prop ? prop.decode(v) : v
        end.freeze
      end
    end
  end
end
