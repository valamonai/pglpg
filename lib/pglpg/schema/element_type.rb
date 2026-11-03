# frozen_string_literal: true

module Pglpg
  module Schema
    NAME_FORMAT = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    def self.check_name!(name, what)
      raise SchemaError, "invalid #{what} name #{name.inspect}" unless name.to_s.match?(NAME_FORMAT)

      name.to_sym
    end

    # Declared properties stay typed. Explicit open types also accept a
    # restricted JSON-native value set without guessing a schema for extras.
    class ElementType
      attr_reader :name

      def initialize(name, open: false)
        raise SchemaError, "open: must be true or false" unless open.equal?(true) || open.equal?(false)

        @name = Schema.check_name!(name, "type")
        @own_properties = {}
        @open = open
      end

      def open? = @open

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

      # @api private
      # Construction-only resolution; the descriptor is frozen afterwards.
      def resolve_open!(columns, parents: [])
        @open ||= parents.any?(&:open?)
        @extra_reserved_names = (Column::RESERVED + Temporal::NAMES + columns.keys).uniq.freeze
      end

      # Normalize before the writer generates/merges keys, so ambiguous
      # String/Symbol aliases cannot disappear before validation.
      # @api private
      def normalize_properties(props)
        return (props || {}).transform_keys(&:to_sym) unless open?

        (props || {}).each_with_object({}) do |(name, value), out|
          unless (name.is_a?(String) || name.is_a?(Symbol)) && name.to_s.match?(NAME_FORMAT)
            raise ValidationError, "invalid open property name"
          end
          name = name.to_sym
          raise ValidationError, "duplicate property #{name}" if out.key?(name)
          if !properties.key?(name) && @extra_reserved_names.include?(name)
            raise ValidationError, "#{name} is reserved and cannot be an extra property"
          end

          out[name] = value
        end
      end

      # Validates +props+ and returns the JSON hash to store. nil values are
      # dropped (null means absent). With +partial+, required properties may be
      # missing but may not be set to nil.
      def encode_properties(props, partial: false)
        props = normalize_properties(props)
        unknown = props.keys - properties.keys
        if !open? && unknown.any?
          raise ValidationError, "#{name} has no propert#{unknown.size == 1 ? "y" : "ies"} #{unknown.join(", ")}"
        end

        required_properties.each do |p|
          next if partial && !props.key?(p.name)
          raise ValidationError, "#{name}.#{p.name} is required" if props[p.name].nil?
        end
        props.each_with_object({}) do |(k, v), out|
          prop = properties[k]
          encoded = prop ? prop.encode(v) : encode_extra(v)
          out[k.to_s] = encoded unless encoded.nil?
        end
      end

      def decode_properties(json)
        (json || {}).each_with_object({}) do |(k, v), out|
          prop = properties[k.to_sym]
          out[k.to_sym] = prop ? prop.decode(v) : freeze_extra(v)
        end.freeze
      end

      private

      def encode_extra(value)
        return nil if value.nil?
        return encode_extra_scalar(value) unless value.instance_of?(Array)

        kinds = value.map { (_1.equal?(true) || _1.equal?(false)) ? :boolean : _1.class }.uniq
        raise ValidationError, "extra property lists must be homogeneous scalar arrays" if kinds.size > 1

        value.map { encode_extra_scalar(_1) }
      end

      def encode_extra_scalar(value)
        if value.instance_of?(String)
          begin
            text = value.encode(Encoding::UTF_8)
          rescue EncodingError
            raise ValidationError, "extra property strings must be valid UTF-8"
          end
          raise ValidationError, "extra property strings must be valid UTF-8" unless text.valid_encoding?
          raise ValidationError, "extra property strings cannot contain NUL" if text.include?("\0")

          return text
        end
        return value if value.instance_of?(Integer) || value.equal?(true) || value.equal?(false)
        return value if value.instance_of?(Float) && value.finite?

        raise ValidationError, "extra property values must be JSON-native scalars or homogeneous scalar arrays"
      end

      def freeze_extra(value)
        case value
        when Array then value.each { freeze_extra(_1) }
        when Hash then value.each { |key, child| freeze_extra(key); freeze_extra(child) }
        end
        value.freeze
      end
    end
  end
end
