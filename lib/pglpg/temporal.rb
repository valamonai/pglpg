# frozen_string_literal: true

require "date"

module Pglpg
  # Internal validity metadata, deliberately separate from application columns.
  module Temporal
    NAMES = %i[valid_from valid_to].freeze
    OMITTED = Object.new.freeze
    MIN = Date.new(1, 1, 1, Date::GREGORIAN).freeze
    MAX = Date.new(9999, 12, 31, Date::GREGORIAN).freeze

    module_function

    # PostgreSQL dates are proleptic Gregorian calendar dates. Interpret Ruby
    # Dates by their civil fields, never by timezone or an implicit Time cast.
    def date(value, error: ValidationError)
      return nil if value.nil?
      raise error, "expected an exact Date in 0001-01-01..9999-12-31" unless value.instance_of?(Date)

      begin
        result = Date.new(value.year, value.month, value.day, Date::GREGORIAN)
      rescue Date::Error
        raise error, "invalid Gregorian date"
      end
      raise error, "date outside 0001-01-01..9999-12-31" unless (MIN..MAX).cover?(result)

      result.freeze
    end

    def bounds(type, lower, upper, required: false)
      supplied = { valid_from: lower, valid_to: upper }.reject { |_, v| v.equal?(OMITTED) }
      unless type.temporal?
        raise ArgumentError, "#{type.name} is not temporal" unless supplied.empty?
        return {}.freeze
      end
      raise ArgumentError, "temporal insert/upsert requires valid_from:" if required && lower.equal?(OMITTED)

      result = supplied.transform_values { date(_1) }
      validate_interval!(result[:valid_from], result[:valid_to])
      result.freeze
    end

    def validate_interval!(lower, upper)
      raise ValidationError, "valid_from must precede valid_to" if lower && upper && lower >= upper
    end
  end
end
