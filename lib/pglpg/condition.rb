# frozen_string_literal: true

module Pglpg
  # A structured property condition. Plain values mean equality, arrays mean
  # "one of", nil means "absent". Use Pglpg.gt(3) and friends for the rest.
  Condition = Data.define(:op, :value) do
    def self.wrap(value)
      case value
      when Condition then value
      when nil then new(op: :absent, value: nil)
      when Array then new(op: :in, value:)
      when Range then raise ArgumentError, "ranges are not supported; combine Pglpg.gte and Pglpg.lte"
      else new(op: :eq, value:)
      end
    end
  end

  Condition::OPS = { gt: ">", gte: ">=", lt: "<", lte: "<=", ne: "<>" }.freeze

  class << self
    def gt(value) = Condition.new(op: :gt, value:)

    def gte(value) = Condition.new(op: :gte, value:)

    def lt(value) = Condition.new(op: :lt, value:)

    def lte(value) = Condition.new(op: :lte, value:)

    def ne(value) = Condition.new(op: :ne, value:)

    def in(values) = Condition.new(op: :in, value: Array(values))
  end
end
