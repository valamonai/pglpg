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
        @preload = {}.freeze
        freeze
      end

      # Structured conditions on the model's properties, as in Query#where.
      def where(**props) = derive(@query.where(var => props))

      # order(:name), order(name: :desc) or order(:rank, name: :desc). Ties are
      # broken by element ids.
      def order(*names, **spec) = derive(order_query(var, names, spec), shaped: true)

      def limit(n) = derive(@query.limit(n), shaped: true)

      def offset(n) = derive(@query.offset(n), shaped: true)

      def to_a
        records = rows
        preload(records, @preload, model) unless @preload.empty?
        records
      end

      # Preload symbols/strings and nested hashes (array values, including [],
      # are allowed). Calls merge; static association/model validation runs
      # now, before SQL: ArgumentError for invalid trees, ConfigurationError
      # for missing target models. to_a/each/first preload; count, exists?,
      # pluck and find do not. Batches above max_rows raise TooManyRows.
      def with_associations(*spec)
        tree = merge_tree(@preload, parse_tree(spec, []))
        validate_tree(model, tree)
        copy = clone(freeze: false)
        copy.instance_variable_set(:@preload, tree)
        copy.freeze
      end

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

      # The values of attributes (or :id, :ref) of each element, in order:
      # one value per element for one name, an Array per element for
      # several. Elements are chosen first and projected afterwards, so two
      # elements with equal values give two values (ADR-0010 §5).
      #   people.order(:name).pluck(:name)        # => ["Ann", "Bob"]
      #   people.pluck(:id, :name)                # => [[1, "Ann"], [2, "Bob"]]
      def pluck(*names)
        names = pluck_names!(model, names)
        raise ArgumentError, "pluck needs at least one name" if names.empty?

        rows.map { |record| unwrap(project(record, names)) }
      end

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

      def rows = compiled.to_a.map { |row| load_row(row) }

      def parse_tree(spec, ancestors)
        raise ArgumentError, "cyclic preload tree" if ancestors.include?(spec.object_id)
        ancestors = ancestors + [spec.object_id]
        result = {}
        spec.each do |item|
          case item
          when Symbol, String
            key = item.to_sym
            result[key] ||= {}.freeze
          when Hash
            raise ArgumentError, "cyclic preload tree" if ancestors.include?(item.object_id)
            item.each do |key, value|
              raise ArgumentError, "invalid association name" unless key.is_a?(Symbol) || key.is_a?(String)
              children = value.is_a?(Array) ? value : [value]
              result[key.to_sym] = merge_tree(result[key.to_sym] || {}, parse_tree(children, ancestors + [item.object_id]))
            end
          else
            raise ArgumentError, "invalid preload specification"
          end
        end
        result.freeze
      end

      def merge_tree(a, b)
        a.merge(b) { |_key, left, right| merge_tree(left, right) }.freeze
      end

      def target_model(owner_model, association)
        owner_model.association_model(association)
      end

      def validate_tree(owner_model, tree)
        tree.each do |name, children|
          association = owner_model.respond_to?(:associations) && owner_model.associations[name]
          raise ArgumentError, "#{owner_model} has no association #{name}" unless association
          validate_tree(target_model(owner_model, association), children)
        end
      end

      def preload(owners, tree, owner_model)
        return if owners.empty?
        tree.each do |name, children|
          association = owner_model.associations.fetch(name)
          target = target_model(owner_model, association)
          query = context.match.node_refs(:owner, owners.map(&:ref))
          query = query.public_send(association.direction, association.edge_type, :n,
                                    association.label || target.schema_type.name, edge: :e)
          begin
            pairs = query.return(:owner, :n).distinct.to_a
          rescue TooManyRows
            raise TooManyRows, "#{owner_model}##{name}: more than #{Pglpg.configuration.max_rows} distinct owner-target pairs; page the owners"
          end
          targets = {}
          grouped = Hash.new { |h, k| h[k] = [] }
          pairs.each do |row|
            element = row.fetch(:n)
            record = targets[element.ref] ||= target.instantiate(context, element)
            grouped[row.fetch(:owner).ref] << record
          end
          owners.each do |owner|
            cache = owner.instance_variable_get(:@association_cache) || {}
            cache[name] = grouped[owner.ref].freeze
            owner.instance_variable_set(:@association_cache, cache)
          end
          preload(targets.values, children, target)
        end
      end

      def var = model.query_var

      # The query that runs.
      def compiled = @query

      def load_row(row) = model.instantiate(context, row.fetch(var))

      PLUCK_IDENTITY = %i[id ref].freeze

      # Checked before any query runs.
      def pluck_names!(model, names)
        names.map(&:to_sym).each do |name|
          next if PLUCK_IDENTITY.include?(name) || model.attribute_names.include?(name.to_s)

          raise ArgumentError, "#{model.name || model.schema_type.name} has no attribute #{name.inspect} to pluck"
        end
      end

      def project(record, names) = names.map { record.public_send(_1) }

      def unwrap(values) = values.size == 1 ? values.first : values

      def order_query(var, names, spec)
        q = names.reduce(@query) { |acc, name| acc.order(var => name) }
        spec.empty? ? q : q.order(var => spec)
      end

      def derived_copy(copy) = copy

      # A copy with +query+; +shaped+ records ordering or pagination.
      def derive(query, shaped: @shaped)
        copy = clone(freeze: false)
        copy.instance_variable_set(:@query, query)
        derived_copy(copy)
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
      def initialize(model, context, query, edge_model:, cached: nil)
        @edge_model = edge_model
        @cached = cached
        super(model, context, query, filtered: true)
      end

      def first(n = nil)
        return super unless @cached
        return to_a.first if n.nil?

        unless n.is_a?(Integer) && n.positive? && n <= Pglpg.configuration.max_rows
          raise ArgumentError, "count must be a positive Integer at most max_rows"
        end
        to_a.first(n).freeze
      end

      def count = @cached ? @cached.size : super
      def exists? = @cached ? !@cached.empty? : super
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
        raise ArgumentError, "with_rel cannot discard pending preloads" unless @preload.empty?

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

      def rows = @cached || super

      def derived_copy(copy)
        copy.instance_variable_set(:@cached, nil)
        super
      end

      def compiled = @query.return(var).distinct
    end

    # The node–edge pairs of an association, from AssociationRelation#with_rel.
    class BindingRelation < AssociationRelation
      # order(...) orders by target properties; rel_order(...) by edge ones.
      def rel_order(*names, **spec) = derive(order_query(:e, names, spec), shaped: true)

      def with_associations(*) = raise(ArgumentError, "preloading binding relations is not supported")

      def with_rel = self

      # One entry per pair: the target's +names+, then the edge's +rel+ names.
      #   ann.projects.with_rel.pluck(:title, rel: :role)  # => [["Apollo", "lead"], ...]
      def pluck(*names, rel: [])
        rel = Array(rel)
        names = pluck_names!(model, names)
        if rel.any?
          @edge_model or raise ConfigurationError, "no model is registered for the association's edge type"
          rel = pluck_names!(@edge_model, rel)
        end
        raise ArgumentError, "pluck needs at least one name" if names.empty? && rel.empty?

        to_a.map { |target, edge| unwrap(project(target, names) + project(edge, rel)) }
      end

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
