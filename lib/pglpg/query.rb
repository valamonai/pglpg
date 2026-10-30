# frozen_string_literal: true

module Pglpg
  # A fixed-length pattern query, built immutably from Context#match.
  #
  #   ctx.match
  #      .node(:p, :Person, uid: "PER-12")
  #      .out(:WORKS_ON, :j, :Project, edge: :w)
  #      .out(:BASED_AT, :l, :Location)
  #      .where(j: { headcount: Pglpg.gt(0) })
  #      .return(:p, :j, :l)
  #      .order(j: :headcount)
  #      .limit(50)
  #
  # The visibility policy is applied to every node and edge in the pattern.
  # Each result row is a frozen Hash from variable to Node or Edge.
  class Query
    include Enumerable

    NodePattern = Data.define(:var, :label, :ref_id, :ref_ids)
    EdgePattern = Data.define(:var, :type, :direction, :from_var, :to_var, :named)
    State = Data.define(:nodes, :edges, :conditions, :returns, :orders, :limit, :offset, :distinct, :last_var)

    EMPTY = State.new(nodes: {}.freeze, edges: [].freeze, conditions: {}.freeze, returns: nil, orders: [].freeze,
                      limit: nil, offset: nil, distinct: false, last_var: nil)

    attr_reader :context

    def initialize(context, state = EMPTY)
      @context = context
      @state = state
      freeze
    end

    # The start node. Properties given as keywords are equality conditions.
    def node(var, label = nil, ref: nil, **props)
      raise ArgumentError, "a pattern has one start node; branch with from:" unless @state.nodes.empty?

      var = new_var!(var)
      label = check_label!(label)
      context.graph.check_ref!(ref, :node) if ref
      q = with(nodes: { var => NodePattern.new(var:, label:, ref_id: ref&.id, ref_ids: nil) }.freeze, last_var: var)
      props.empty? ? q : q.where(var => props)
    end

    # Internal batched start. A pattern has either ref_id or ref_ids, never both.
    def node_refs(var, refs)
      raise ArgumentError, "a pattern has one start node" unless @state.nodes.empty?

      var = new_var!(var)
      refs.each { context.graph.check_ref!(_1, :node) }
      pattern = NodePattern.new(var:, label: nil, ref_id: nil, ref_ids: refs.map(&:id).freeze)
      with(nodes: { var => pattern }.freeze, last_var: var)
    end

    # Follows an outgoing edge of +type+ from +from+ (default: the last node).
    def out(type, var, label = nil, edge: nil, from: nil, **props) = hop(:out, type, var, label, edge, from, props)

    # Follows an incoming edge of +type+ into +from+ (default: the last node).
    def in(type, var, label = nil, edge: nil, from: nil, **props) = hop(:in, type, var, label, edge, from, props)

    # Follows an edge of a symmetric +type+ from +from+ (default: the last
    # node), whichever end it is stored at: GQL's ~[ ]~ (ADR-0008). Each edge
    # binds once per orientation that fits, so a self-loop binds once.
    def both(type, var, label = nil, edge: nil, from: nil, **props) = hop(:both, type, var, label, edge, from, props)

    # Structured conditions per variable: where(j: { headcount: Pglpg.gt(0) }).
    def where(by_var)
      conditions = @state.conditions.transform_values(&:dup)
      by_var.each do |var, props|
        var = var.to_sym
        element_type = element_type!(var)
        props.each do |name, value|
          prop = element_type.property_named(name) or
            raise ArgumentError, "#{element_type.name} has no property #{name.inspect}"
          raise ArgumentError, "list property #{prop.name} cannot be filtered in 0.1" unless prop.comparable?

          condition = Condition.wrap(value)
          validate_condition!(prop, condition)
          (conditions[var] ||= []) << [prop, condition]
        end
      end
      with(conditions: conditions.transform_values(&:freeze).freeze)
    end

    def return(*vars)
      vars = vars.flatten.map(&:to_sym)
      raise ArgumentError, "return needs at least one variable" if vars.empty?

      vars.each { |v| raise ArgumentError, "#{v} is not a returnable variable" unless returnable.include?(v) }
      with(returns: vars.uniq.freeze)
    end

    # order(j: :headcount) or order(j: { name: :desc }). Ties are broken by
    # element ids, so the order is deterministic.
    def order(by_var)
      orders = @state.orders.dup
      by_var.each do |var, spec|
        var = var.to_sym
        element_type = element_type!(var)
        spec = { spec => :asc } unless spec.is_a?(Hash)
        spec.each do |name, dir|
          prop = element_type.property_named(name) or
            raise ArgumentError, "#{element_type.name} has no property #{name.inspect}"
          raise ArgumentError, "direction must be :asc or :desc" unless %i[asc desc].include?(dir)
          raise ArgumentError, "list property #{prop.name} cannot be ordered" unless prop.comparable?

          orders << [var, prop, dir]
        end
      end
      with(orders: orders.freeze)
    end

    def limit(n)
      raise ArgumentError, "limit must be a positive Integer" unless n.is_a?(Integer) && n.positive?
      raise ArgumentError, "limit exceeds max_rows (#{max_rows})" if n > max_rows

      with(limit: n)
    end

    def offset(n)
      raise ArgumentError, "offset must be a non-negative Integer" unless n.is_a?(Integer) && !n.negative?

      with(offset: n)
    end

    def distinct = with(distinct: true)

    def to_a
      raise ArgumentError, "the pattern has no start node" if @state.nodes.empty?

      rows = context.read(compile(:rows))
      if @state.limit.nil? && rows.size > max_rows
        raise TooManyRows, "more than #{max_rows} rows; add a limit"
      end

      rows.map { |row| decode(row) }
    end

    def each(&) = to_a.each(&)

    def first = limit(1).to_a.first

    def count = context.read(compile(:count)).first["count"].to_i

    def exists? = context.read(compile(:exists)).first["exists"] == true

    # The SQL and bind values, for tests and debugging.
    def to_sql
      sql = compile(:rows)
      [sql.to_s, sql.binds.map(&:value)]
    end

    # EXPLAIN output for the query, one line per entry. Runs under the same
    # statement timeout as other reads, since ANALYZE executes the query.
    def explain(analyze: false, buffers: false)
      options = ["FORMAT TEXT", ("ANALYZE" if analyze), ("BUFFERS" if buffers)].compact.join(", ")
      sql = compile(:rows).prepend("EXPLAIN (#{options}) ")
      context.read(sql).map { _1.fetch("QUERY PLAN") }
    end

    def inspect = "#<Pglpg::Query #{to_sql.first}>"

    private

    def with(**changes) = Query.new(context, @state.with(**changes))

    def max_rows = Pglpg.configuration.max_rows

    def hop(direction, type, var, label, edge, from, props)
      raise ArgumentError, "start the pattern with node" if @state.nodes.empty?

      edge_type = context.graph.type.edge_type!(type)
      if edge_type.symmetric? && direction != :both
        raise ArgumentError, "#{edge_type.name} is symmetric; use both"
      elsif !edge_type.symmetric? && direction == :both
        raise ArgumentError, "#{edge_type.name} is directed; use out or in"
      end

      from = (from || @state.last_var).to_sym
      raise ArgumentError, "#{from} is not a node variable" unless @state.nodes.key?(from)

      var = var.to_sym
      label = check_label!(label)
      nodes = @state.nodes
      if nodes.key?(var)
        if label && label != nodes[var].label
          raise ArgumentError, "#{var} is already bound with label #{nodes[var].label.inspect}"
        end
      else
        new_var!(var)
        nodes = nodes.merge(var => NodePattern.new(var:, label:, ref_id: nil, ref_ids: nil)).freeze
      end

      # Checked against the node map including this hop's new node.
      edge_var = edge ? new_var!(edge, nodes) : :"_e#{@state.edges.size}"
      pattern = EdgePattern.new(var: edge_var, type: edge_type.name, direction:, from_var: from, to_var: var,
                                named: !edge.nil?)
      q = with(nodes:, edges: (@state.edges + [pattern]).freeze, last_var: var)
      props.empty? ? q : q.where(var => props)
    end

    def new_var!(var, nodes = @state.nodes)
      var = var.to_sym
      raise ArgumentError, "variable names starting with _ are reserved" if var.start_with?("_")
      if nodes.key?(var) || @state.edges.any? { _1.var == var }
        raise ArgumentError, "variable #{var} is already bound"
      end

      var
    end

    def check_label!(label)
      return nil if label.nil?

      context.graph.type.node_type!(label).name
    end

    # The type whose properties a variable may be filtered and ordered by.
    def element_type!(var)
      if (node = @state.nodes[var])
        raise ArgumentError, "give #{var} a label to filter or order by its properties" unless node.label

        return context.graph.type.node_type!(node.label)
      end
      edge = @state.edges.find { _1.var == var && _1.named }
      raise ArgumentError, "unknown variable #{var.inspect}" unless edge

      context.graph.type.edge_type!(edge.type)
    end

    def returnable = @state.nodes.keys + @state.edges.select(&:named).map(&:var)

    def returns = @state.returns || returnable

    # -- compilation -----------------------------------------------------------

    def aliases
      node_aliases = @state.nodes.keys.each_with_index.to_h { |v, i| [v, "n#{i}"] }
      edge_aliases = @state.edges.each_with_index.to_h { |e, i| [e.var, "e#{i}"] }
      node_aliases.merge(edge_aliases)
    end

    def compile(kind)
      if @state.distinct && (stray = @state.orders.map(&:first) - returns).any?
        raise ArgumentError, "with distinct, order only by returned variables (not #{stray.join(", ")})"
      end

      names = aliases
      sql = Sql.new(context.graph.connection)
      inner = kind != :rows
      sql << (kind == :count ? "SELECT count(*) AS count FROM (" : "SELECT EXISTS (") if inner
      sql << "SELECT "
      sql << "DISTINCT " if @state.distinct
      select_list(sql, kind, names)
      body(sql, names)
      order_by(sql, names) if kind == :rows
      if kind == :rows
        sql << " LIMIT "
        sql.bind(@state.limit || (max_rows + 1), "bigint")
      elsif @state.limit
        sql << " LIMIT "
        sql.bind(@state.limit, "bigint")
      end
      if @state.offset
        sql << " OFFSET "
        sql.bind(@state.offset, "bigint")
      end
      sql << (kind == :count ? ") AS pglpg_rows" : ") AS \"exists\"") if inner
      sql
    end

    def select_list(sql, kind, names)
      if kind == :rows
        returns.each_with_index do |var, i|
          sql << ", " if i.positive?
          sql << "to_jsonb(" << names.fetch(var) << ") AS " << context.graph.connection.quote_column_name(var.to_s)
        end
        if @state.distinct
          @state.orders.each_with_index do |(var, prop, _), i|
            sql << ", "
            order_expr(sql, names.fetch(var), prop)
            sql << " AS _o#{i}"
          end
          returns.each_with_index { |var, i| sql << ", " << names.fetch(var) << ".id AS _i#{i}" }
        end
      elsif @state.distinct
        returns.each_with_index do |var, i|
          sql << ", " if i.positive?
          sql << names.fetch(var) << ".id"
        end
      else
        sql << "1"
      end
    end

    def body(sql, names)
      nodes_table = context.table_sql(context.graph.nodes_table)
      edges_table = context.table_sql(context.graph.edges_table)
      start = @state.nodes.values.first
      sql << " FROM " << nodes_table << " AS " << names.fetch(start.var)
      bound = [start.var]

      @state.edges.each_with_index do |edge, i|
        e = names.fetch(edge.var)
        x = "#{names.fetch(edge.from_var)}.id"
        sql << " JOIN " << edges_table << " AS " << e << " ON "
        case edge.direction
        when :out
          sql << e << ".source_id = " << x
          far = "#{e}.target_id"
        when :in
          sql << e << ".target_id = " << x
          far = "#{e}.source_id"
        else
          # Either stored column; the far end is the other one. A self-loop
          # matches both conditions but is still one row.
          sql << "(" << e << ".source_id = " << x << " OR " << e << ".target_id = " << x << ")"
          far = "(CASE WHEN #{e}.source_id = #{x} THEN #{e}.target_id ELSE #{e}.source_id END)"
        end
        sql << " AND " << e << ".type = "
        sql.bind(edge.type.to_s, "text")
        sql << " AND "
        context.append_edge_visible(sql, e)
        conditions_sql(sql, edge.var, e)
        # Different edges (the GQL default match mode).
        @state.edges.first(i).each do |other|
          sql << " AND " << e << ".id <> " << names.fetch(other.var) << ".id" if other.type == edge.type
        end

        if bound.include?(edge.to_var)
          sql << " AND " << far << " = " << names.fetch(edge.to_var) << ".id"
        else
          n = names.fetch(edge.to_var)
          sql << " JOIN " << nodes_table << " AS " << n << " ON " << n << ".id = " << far << " AND "
          node_conditions(sql, @state.nodes.fetch(edge.to_var), n)
          bound << edge.to_var
        end
      end

      sql << " WHERE "
      node_conditions(sql, start, names.fetch(start.var))
    end

    def node_conditions(sql, node, n)
      context.append_node_visible(sql, n)
      if node.label
        # A literal, so the planner can match partial (key) indexes.
        sql << " AND " << n << ".labels @> ARRAY["
        sql.literal(node.label) << "]::text[]"
      end
      if node.ref_id
        sql << " AND " << n << ".id = "
        sql.bind(node.ref_id, "bigint")
      end
      if node.ref_ids
        sql << " AND " << n << ".id = ANY("
        sql.bind_text_array(node.ref_ids.map(&:to_s))
        sql << "::bigint[])"
      end
      conditions_sql(sql, node.var, n)
    end

    def conditions_sql(sql, var, a)
      key = key_of(var)
      (@state.conditions[var] || []).each do |prop, cond|
        sql << " AND "
        case cond.op
        when :eq
          if key && key.property == prop.name
            # Matches the key's partial unique index.
            sql << a << ".labels @> ARRAY["
            sql.literal(key.declared_on) << "]::text[] AND (" << a << ".properties ->> "
            sql.literal(prop.name) << ") = "
            sql.bind(prop.encode(cond.value), "text")
            next
          end
          sql << a << ".properties @> "
          sql.bind_json({ prop.name.to_s => prop.encode(cond.value) })
        when :absent
          sql << "(" << a << ".properties -> "
          sql.literal(prop.name) << ") IS NULL"
        when :in
          order_expr(sql, a, prop)
          sql << " = ANY("
          sql.bind_text_array(cond.value.map { encoded_text(prop, _1) })
          sql << "::#{prop.sql_cast}[])"
        else
          order_expr(sql, a, prop)
          sql << " " << Condition::OPS.fetch(cond.op) << " "
          sql.bind(encoded_text(prop, cond.value), "text")
          sql << "::#{prop.sql_cast}"
        end
      end
    end

    def key_of(var)
      label = @state.nodes[var]&.label
      label && context.graph.type.node_type!(label).key
    end

    # Validates values up front, so errors surface where the query is built.
    def validate_condition!(prop, condition)
      case condition.op
      when :absent then nil
      when :in
        raise ArgumentError, "#{prop.name}: in needs at least one value" if condition.value.empty?

        condition.value.each { encoded_text(prop, _1) }
      else encoded_text(prop, condition.value)
      end
    end

    def encoded_text(prop, value)
      raise ArgumentError, "#{prop.name}: nil is only allowed as a plain value (absent)" if value.nil?

      prop.encode(value).to_s
    end

    def order_expr(sql, a, prop)
      sql << "(" << a << ".properties ->> "
      sql.literal(prop.name) << ")::#{prop.sql_cast}"
    end

    def order_by(sql, names)
      sql << " ORDER BY "
      parts = 0
      @state.orders.each_with_index do |(var, prop, dir), i|
        sql << ", " if parts.positive?
        @state.distinct ? sql << "_o#{i}" : order_expr(sql, names.fetch(var), prop)
        sql << (dir == :desc ? " DESC NULLS LAST" : " ASC NULLS LAST")
        parts += 1
      end
      id_vars = @state.distinct ? returns : names.keys
      id_vars.each_with_index do |var, i|
        sql << ", " if parts.positive?
        @state.distinct ? sql << "_i#{i}" : sql << names.fetch(var) << ".id"
        parts += 1
      end
    end

    def decode(row)
      returns.to_h do |var|
        json = JSON.parse(row.fetch(var.to_s))
        element = @state.nodes.key?(var) ? context.graph.build_node(json) : context.graph.build_edge(json)
        [var, element]
      end.freeze
    end
  end
end
