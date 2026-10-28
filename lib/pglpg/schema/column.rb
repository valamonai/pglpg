# frozen_string_literal: true

module Pglpg
  module Schema
    # An application column on the nodes or edges table, such as
    # +classification+. Visibility policies filter on these real, indexed
    # columns; writes set them through +attrs:+. Options: +null:+, +default:+,
    # +limit:+, +precision:+, +scale:+ and, for edge columns, +covering: true+.
    class Column
      RESERVED = %i[id key_label labels properties type source_id target_id created_at updated_at].freeze

      attr_reader :name, :type, :options

      def initialize(name, type, **options)
        @name = Schema.check_name!(name, "column")
        raise SchemaError, "#{@name} is a reserved column name" if RESERVED.include?(@name)

        @type = type.to_sym
        @options = options.freeze
        freeze
      end

      def null? = options.fetch(:null, true)

      # Included in the edge traversal indexes (edge columns only).
      def covering? = options.fetch(:covering, false)

      def default? = options.key?(:default)

      # Required on insert: NOT NULL and no default.
      def required? = !null? && !default?

      def sql_type(connection)
        connection.type_to_sql(type, **options.slice(:limit, :precision, :scale))
      end
    end
  end
end
