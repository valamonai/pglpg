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
        @shaped = false
        freeze
      end

      # Structured conditions on the model's properties, as in Query#where.
      def where(**props) = derive(@query.where(var => props))

      # order(:name), order(name: :desc) or order(:rank, name: :desc). Ties are
      # broken by element ids.
      def order(*names, **spec) = derive(order_query(var, names, spec), shaped: true)

      def limit(n) = derive(@query.limit(n), shaped: true)

      def offset(n) = derive(@query.offset(n), shaped: true)

      def to_a = compiled.to_a.map { |row| load_row(row) }

      def each(&) = to_a.each(&)

      def first(n = nil) = n.nil? ? limit(1).to_a.first : limit(n).to_a

      def count = compiled.count

      def exists? = compiled.exists?

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

      # A new record bound to the relation's context.
      def new(**attributes) = model.build(context, attributes)

      alias build new

      # Builds and saves a record; returns it, saved or not (check
      # persisted? or errors).
      def create(writer: nil, **attributes) = new(**attributes).tap { _1.save(writer:) }

      # As #create, but raises RecordInvalid when validation fails.
      def create!(writer: nil, **attributes) = new(**attributes).tap { _1.save!(writer:) }

      # The compiled Pglpg::Query, for debugging (to_sql, explain).
      def to_query = compiled

      def inspect = "#<#{self.class.name} #{model.name || model.base_class.name} #{compiled.to_sql.first}>"

      private

      def var = model.query_var

      # The query that runs.
      def compiled = @query

      def load_row(row) = model.instantiate(context, row.fetch(var))

      def order_query(var, names, spec)
        q = names.reduce(@query) { |acc, name| acc.order(var => name) }
        spec.empty? ? q : q.order(var => spec)
      end

      # A copy with +query+; +shaped+ records ordering or pagination.
      def derive(query, shaped: @shaped)
        copy = clone(freeze: false)
        copy.instance_variable_set(:@query, query)
        copy.instance_variable_set(:@filtered, true)
        copy.instance_variable_set(:@shaped, shaped)
        copy.freeze
      end
    end

    # The targets of an association (ADR-0010 §5): one row per distinct
    # visible target, deduplicated before ordering, pagination and counts.
    # Edge conditions (rel_where) mean "at least one matching visible edge".
    #
    #   person.projects.rel_where(role: "lead").order(:title).limit(20)
    #   person.projects.with_rel.each { |project, works_on| ... }
    class AssociationRelation < Relation
      def initialize(model, context, query, edge_model:)
        @edge_model = edge_model
        super(model, context, query, filtered: true)
      end

      # Structured conditions on the association's edge properties.
      def rel_where(**props) = derive(@query.where(e: props))

      # A target has no single edge value when several edges lead to it.
      def rel_order(*, **)
        raise ArgumentError, "a target query can't be ordered by an edge property; use with_rel.rel_order"
      end

      # One row per matching node–edge pair: [target, edge]. Its count,
      # limit and offset count pairs. Only on a relation without order,
      # limit or offset, so pagination always applies to the shape it was
      # written for.
      def with_rel
        raise ArgumentError, "call with_rel before order, limit or offset" if @shaped

        BindingRelation.new(model, context, @query, edge_model: @edge_model)
      end

      # Enumerates with_rel: yields each target with its edge.
      def each_with_rel(&) = with_rel.each(&)

      # Creating targets or edges through an association is deferred (ADR-0010).
      def new(**) = raise(ArgumentError, "associations can't build records yet; use Model.in(ctx).new")

      alias build new
      alias create new
      alias create! new

      private

      def compiled = @query.return(var).distinct
    end

    # The node–edge pairs of an association, from AssociationRelation#with_rel.
    class BindingRelation < AssociationRelation
      # order(...) orders by target properties; rel_order(...) by edge ones.
      def rel_order(*names, **spec) = derive(order_query(:e, names, spec), shaped: true)

      def with_rel = self

      def each_with_rel(&) = each(&)

      private

      def compiled = @query.return(var, :e)

      def load_row(row)
        edge_model = @edge_model or
          raise ConfigurationError, "no model is registered for edge type #{row.fetch(:e).type}"
        [model.instantiate(context, row.fetch(var)), edge_model.instantiate(context, row.fetch(:e))]
      end
    end
  end
end
