# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

module Pglpg
  module Schema
    # A declared property: name, value type and whether it is required.
    # Values are stored in the +properties+ jsonb column. A nil value means the
    # property is absent, as in GQL.
    class Property
      SCALAR_TYPES = %i[string integer float decimal boolean date datetime enum].freeze
      TYPES = (SCALAR_TYPES + %i[list]).freeze

      # jsonb_typeof of a stored value, per type.
      JSON_TYPES = {
        string: "string", integer: "number", float: "number", decimal: "string",
        boolean: "boolean", date: "string", datetime: "string", enum: "string", list: "array"
      }.freeze

      # SQL cast used to compare a stored value (extracted as text).
      SQL_CASTS = {
        string: "text", integer: "numeric", float: "double precision", decimal: "numeric",
        boolean: "boolean", date: "date", datetime: "timestamptz", enum: "text"
      }.freeze

      attr_reader :name, :type, :values, :of

      def initialize(name, type, required: false, values: nil, of: nil)
        @name = name.to_sym
        @type = type.to_sym
        @required = required ? true : false
        @values = values&.map(&:to_s)&.freeze
        @of = of&.to_sym
        check!
        freeze
      end

      def required? = @required

      def json_type = JSON_TYPES.fetch(type)

      def sql_cast = SQL_CASTS.fetch(type)

      def comparable? = type != :list

      def same_definition?(other)
        other.type == type && other.required? == required? && other.values == values && other.of == of
      end

      # Validates a Ruby value and returns its JSON form. nil stays nil.
      def encode(value)
        return nil if value.nil?
        return encode_scalar(type, value) unless type == :list
        raise ValidationError, "#{name} must be an Array" unless value.is_a?(Array)

        value.map do |v|
          raise ValidationError, "#{name} must not contain nil" if v.nil?

          encode_scalar(of, v)
        end
      end

      # Turns a stored JSON value back into Ruby.
      def decode(json)
        return nil if json.nil?
        return decode_scalar(type, json) unless type == :list

        json.map { |v| decode_scalar(of, v) }
      end

      private

      def check!
        raise SchemaError, "unknown property type #{type.inspect} for #{name}" unless TYPES.include?(type)
        if type == :enum && (values.nil? || values.empty?)
          raise SchemaError, "enum property #{name} needs values:"
        end
        return unless type == :list
        return if SCALAR_TYPES.include?(of) && of != :enum

        raise SchemaError, "list property #{name} needs of: with a scalar type"
      end

      def encode_scalar(t, v)
        case t
        when :string
          return v if v.is_a?(String)
        when :integer
          return v if v.is_a?(Integer)
        when :float
          return v.to_f if v.is_a?(Numeric) && !v.is_a?(BigDecimal) && v.to_f.finite?
        when :decimal
          return v.to_s("F") if v.is_a?(BigDecimal) && v.finite?
          return BigDecimal(v).to_s("F") if v.is_a?(Integer)
        when :boolean
          return v if [true, false].include?(v)
        when :date
          return v.iso8601 if v.instance_of?(Date)
        when :datetime
          return v.to_time.utc.iso8601(6) if v.is_a?(Time) || v.is_a?(DateTime) || time_with_zone?(v)
        when :enum
          return v.to_s if (v.is_a?(String) || v.is_a?(Symbol)) && values.include?(v.to_s)
        end
        raise ValidationError, "invalid #{t} value for #{name}: #{v.inspect}"
      end

      def time_with_zone?(v)
        defined?(ActiveSupport::TimeWithZone) && v.is_a?(ActiveSupport::TimeWithZone)
      end

      def decode_scalar(t, v)
        case t
        when :decimal then BigDecimal(v)
        when :date then Date.iso8601(v)
        when :datetime then Time.iso8601(v)
        else v
        end
      end
    end
  end
end
