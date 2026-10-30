# frozen_string_literal: true

module Pglpg
  module Model
    # A query over one model's elements as seen through a Context, built
    # immutably from Model.in. It compiles to a Pglpg::Query, so the
    # visibility policy, deterministic ordering, max_rows and the statement
    # timeout all apply as they do there.
    #
    #   Person.in(ctx).where(rank: Pglpg.gte(2)).order(name: :desc).limit(20)
    class Relation
      include Enumerable

      attr_reader :model, :context

      def initialize(model, context, query = nil, filtered: false)
        @model = model
        @context = context
        @query = query || model.pattern(context)
        @filtered = filtered
        freeze
      end

      # Structured conditions on the model's properties, as in Query#where.
      def where(**props) = narrow(@query.where(var => props))

      # order(:name), order(name: :desc) or order(:rank, name: :desc). Ties are
      # broken by element ids.
      def order(*names, **spec)
        q = names.reduce(@query) { |acc, name| acc.order(var => name) }
        narrow(spec.empty? ? q : q.order(var => spec))
      end

      def limit(n) = narrow(@query.limit(n))

      def offset(n) = narrow(@query.offset(n))

      def to_a = @query.to_a.map { |row| model.instantiate(context, row.fetch(var)) }

      def each(&) = to_a.each(&)

      def first(n = nil) = n.nil? ? limit(1).to_a.first : limit(n).to_a

      def count = @query.count

      def exists? = @query.exists?

      # The visible element of the model's type behind +ref+ (a Ref or its
      # String form). Raises RecordNotFound when it is missing or hidden.
      # Conditions, ordering and pagination do not apply, so find works only
      # on the unfiltered relation.
      def find(ref)
        raise ArgumentError, "find ignores conditions and pagination; use where(...).first" if @filtered

        ref = model.graph.parse_ref(ref) if ref.is_a?(String)
        model.graph.check_ref!(ref, model.kind)
        element = context.find(ref)
        raise RecordNotFound unless element && model.matches?(element)

        model.instantiate(context, element)
      end

      # The first element matching +props+, or nil.
      def find_by(**props) = where(**props).first

      # The compiled Pglpg::Query, for debugging (to_sql, explain).
      def to_query = @query

      def inspect = "#<#{self.class.name} #{model.name || model.base_class.name} #{@query.to_sql.first}>"

      private

      def var = model.query_var

      def narrow(query) = Relation.new(model, context, query, filtered: true)
    end
  end
end
