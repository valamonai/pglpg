# frozen_string_literal: true

require "pg"

module Pglpg
  # Builds one SQL statement with numbered bind parameters. It doubles as an
  # Arel collector, so policy conditions (Arel nodes) compile straight into
  # the statement and keep their own binds.
  class Sql
    ARRAY_ENCODER = PG::TextEncoder::Array.new

    attr_reader :binds
    attr_accessor :preparable, :retryable

    def initialize(connection)
      @connection = connection
      @parts = []
      @binds = []
    end

    def <<(str)
      @parts << str
      self
    end

    # Appends a bound value, optionally with a cast: "$3::jsonb".
    def bind(value, cast = nil)
      add_bind(ActiveRecord::Relation::QueryAttribute.new("", value, ActiveModel::Type::Value.new))
      self << "::#{cast}" if cast
      self
    end

    def bind_json(value) = bind(JSON.generate(value), "jsonb")

    def bind_text_array(values) = bind(ARRAY_ENCODER.encode(values.map(&:to_s)), "text[]")

    def ident(name) = self << @connection.quote_column_name(name.to_s)

    def table(name) = self << @connection.quote_table_name(name.to_s)

    # A schema-defined string (type or label name) as a SQL literal. Used where
    # PostgreSQL needs a constant, such as ON CONFLICT index inference.
    def literal(str) = self << @connection.quote(str.to_s)

    # Compiles an Arel node into the statement.
    def arel(node)
      @connection.visitor.compile(node, self)
      self
    end

    # Arel collector interface.
    def add_bind(attribute, &)
      @binds << attribute
      self << "$#{@binds.size}"
    end

    def add_binds(attributes, _proc_for_binds = nil, &)
      attributes.each_with_index do |attribute, i|
        self << ", " if i.positive?
        add_bind(attribute)
      end
      self
    end

    def value = self

    # Puts +str+ before the statement built so far (binds keep their numbers).
    def prepend(str)
      @parts.unshift(str)
      self
    end

    def to_s = @parts.join
  end
end
