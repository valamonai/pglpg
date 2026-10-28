# frozen_string_literal: true

module Pglpg
  # What a write asks for, as passed to the write policy.
  #   operation: :insert_node, :update_node, :upsert_node, :delete_node,
  #              :insert_edge, :update_edge, :upsert_edge or :delete_edge
  #   type:      the node or edge type
  #   target:    the Ref being changed (update and delete), else nil
  #   from, to:  endpoint Refs for edge inserts and upserts
  #   key:       the key for upserts
  WriteRequest = Data.define(:viewer, :operation, :type, :target, :from, :to, :key, :properties, :attrs, :trusted)

  # Compiles writes into single statements. Visibility of the existing row,
  # the policy's conditions on it and endpoint checks all run inside the
  # statement, so they hold against the row the statement actually touches,
  # even under concurrent writes.
  class Writer
    def initialize(context, trusted:)
      @context = context
      @graph = context.graph
      @trusted = trusted
    end

    def insert_node(type, properties: {}, attrs: {})
      node_type = concrete_node_type!(type)
      props = properties.transform_keys(&:to_sym)
      if (key = node_type.key)
        if props.key?(key.property)
          raise ArgumentError, "#{node_type.name}.#{key.property} is a key and is generated" unless @trusted
        else
          props[key.property] = key.generate(node_type.name)
        end
      end
      json = node_type.encode_properties(props)
      cols = encode_attrs(@graph.type.node_columns, attrs, insert: true)
      authorize!(:insert_node, node_type.name, properties: props, attrs:)

      sql = new_sql
      insert_node_values(sql, node_type, json, cols)
      sql << " RETURNING id"
      ref(:node, write(sql))
    end

    def update_node(ref, properties: {}, attrs: {})
      @graph.check_ref!(ref, :node)
      node = @context.find(ref) or raise WriteRejected
      node_type = @graph.type.node_type!(node.key_label)
      props = properties.transform_keys(&:to_sym)
      raise ArgumentError, "keys cannot be changed" if node_type.key && props.key?(node_type.key.property)

      json = node_type.encode_properties(props, partial: true)
      cols = encode_attrs(@graph.type.node_columns, attrs, insert: false)
      request = authorize!(:update_node, node_type.name, target: ref, properties: props, attrs:)

      sql = new_sql
      sql << "UPDATE " << table(@graph.nodes_table) << " AS tgt SET "
      set_properties(sql, "tgt.properties", json, null_keys(props))
      set_columns(sql, cols)
      sql << " WHERE tgt.id = "
      sql.bind(ref.id, "bigint") << " AND tgt.key_label = "
      sql.bind(node_type.name.to_s, "text") << " AND "
      existing_row(sql, :node, request)
      sql << " RETURNING tgt.id"
      self.ref(:node, write(sql))
    end

    # Trusted only. Inserts, or updates the node of the same type with this key.
    def upsert_node(type, key:, properties: {}, attrs: {})
      trusted!(:upsert_node)
      node_type = concrete_node_type!(type)
      node_key = node_type.key or raise ArgumentError, "#{node_type.name} has no key"
      key = key.transform_keys(&:to_sym)
      raise ArgumentError, "#{node_type.name} is upserted by #{node_key.property.inspect}" unless key.keys == [node_key.property]

      props = properties.transform_keys(&:to_sym)
      raise ArgumentError, "pass the key in key:, not properties:" if props.key?(node_key.property)

      props = props.merge(key)
      json = node_type.encode_properties(props)
      cols = encode_attrs(@graph.type.node_columns, attrs, insert: true)
      request = authorize!(:upsert_node, node_type.name, key:, properties: props, attrs:)

      sql = new_sql
      insert_node_values(sql, node_type, json, cols)
      sql << " ON CONFLICT ((properties->>"
      sql.literal(node_key.property) << ")) WHERE labels @> ARRAY["
      sql.literal(node_key.declared_on) << "]::text[] DO UPDATE SET "
      set_properties(sql, "tgt.properties", json, null_keys(props), excluded: true)
      set_columns(sql, cols, excluded: true)
      sql << " WHERE tgt.key_label = EXCLUDED.key_label AND "
      existing_row(sql, :node, request)
      sql << " RETURNING id"
      ref(:node, write(sql))
    end

    # Trusted only. Nodes that still have edges cannot be deleted.
    def delete_node(ref)
      trusted!(:delete_node)
      @graph.check_ref!(ref, :node)
      node = @context.find(ref) or raise WriteRejected
      request = authorize!(:delete_node, node.key_label, target: ref)

      sql = new_sql
      sql << "DELETE FROM " << table(@graph.nodes_table) << " AS tgt WHERE tgt.id = "
      sql.bind(ref.id, "bigint") << " AND tgt.key_label = "
      sql.bind(node.key_label.to_s, "text") << " AND "
      existing_row(sql, :node, request)
      sql << " RETURNING tgt.id"
      write(sql)
      true
    end

    def insert_edge(type, from:, to:, properties: {}, attrs: {})
      edge_type = @graph.type.edge_type!(type)
      if edge_type.unique_pair? && !@trusted
        raise ArgumentError, "#{edge_type.name} is unique per pair; write it through the trusted writer"
      end

      write_edge(:insert_edge, edge_type, from, to, properties, attrs)
    end

    # Trusted only, for edge types declared unique: :pair.
    def upsert_edge(type, from:, to:, properties: {}, attrs: {})
      trusted!(:upsert_edge)
      edge_type = @graph.type.edge_type!(type)
      raise ArgumentError, "#{edge_type.name} is not unique per pair; use insert_edge" unless edge_type.unique_pair?

      write_edge(:upsert_edge, edge_type, from, to, properties, attrs)
    end

    def update_edge(ref, properties: {}, attrs: {})
      @graph.check_ref!(ref, :edge)
      edge = @context.find(ref) or raise WriteRejected
      edge_type = @graph.type.edge_type!(edge.type)
      props = properties.transform_keys(&:to_sym)
      json = edge_type.encode_properties(props, partial: true)
      cols = encode_attrs(@graph.type.edge_columns, attrs, insert: false)
      request = authorize!(:update_edge, edge_type.name, target: ref, properties: props, attrs:)

      sql = new_sql
      sql << "UPDATE " << table(@graph.edges_table) << " AS tgt SET "
      set_properties(sql, "tgt.properties", json, null_keys(props))
      set_columns(sql, cols)
      sql << " FROM " << table(@graph.nodes_table) << " AS s, " << table(@graph.nodes_table) << " AS t"
      edge_row_condition(sql, ref, edge_type, request)
      sql << " RETURNING tgt.id"
      self.ref(:edge, write(sql))
    end

    def delete_edge(ref)
      @graph.check_ref!(ref, :edge)
      edge = @context.find(ref) or raise WriteRejected
      request = authorize!(:delete_edge, edge.type, target: ref)

      sql = new_sql
      sql << "DELETE FROM " << table(@graph.edges_table) << " AS tgt USING "
      sql << table(@graph.nodes_table) << " AS s, " << table(@graph.nodes_table) << " AS t"
      edge_row_condition(sql, ref, @graph.type.edge_type!(edge.type), request)
      sql << " RETURNING tgt.id"
      write(sql)
      true
    end

    private

    def write_edge(operation, edge_type, from, to, properties, attrs)
      @graph.check_ref!(from, :node)
      @graph.check_ref!(to, :node)
      props = properties.transform_keys(&:to_sym)
      json = edge_type.encode_properties(props)
      cols = encode_attrs(@graph.type.edge_columns, attrs, insert: true)
      request = authorize!(operation, edge_type.name, from:, to:, properties: props, attrs:)

      sql = new_sql
      sql << "INSERT INTO " << table(@graph.edges_table) << " AS tgt (type, source_id, target_id, properties"
      cols.each { |c, _| sql << ", " << ident(c.name) }
      sql << ") SELECT "
      sql.bind(edge_type.name.to_s, "text") << ", s.id, t.id, "
      sql.bind_json(json)
      cols.each do |c, v|
        sql << ", "
        sql.bind(v, c.sql_type(@graph.connection))
      end
      sql << " FROM " << table(@graph.nodes_table) << " AS s, " << table(@graph.nodes_table) << " AS t WHERE s.id = "
      sql.bind(from.id, "bigint") << " AND t.id = "
      sql.bind(to.id, "bigint") << " AND s.labels @> "
      sql.bind_text_array([edge_type.from]) << " AND t.labels @> "
      sql.bind_text_array([edge_type.to]) << " AND "
      @context.append_node_visible(sql, "s")
      sql << " AND "
      @context.append_node_visible(sql, "t")
      # Endpoints stay locked against concurrent change until commit.
      sql << " FOR SHARE OF s, t"
      if operation == :upsert_edge
        sql << " ON CONFLICT (source_id, target_id) WHERE type = "
        sql.literal(edge_type.name) << " DO UPDATE SET "
        set_properties(sql, "tgt.properties", json, null_keys(props), excluded: true)
        set_columns(sql, cols, excluded: true)
        sql << " WHERE "
        existing_row(sql, :edge, request)
      end
      sql << " RETURNING id"
      ref(:edge, write(sql))
    end

    def insert_node_values(sql, node_type, json, cols)
      sql << "INSERT INTO " << table(@graph.nodes_table) << " AS tgt (key_label, labels, properties"
      cols.each { |c, _| sql << ", " << ident(c.name) }
      sql << ") VALUES ("
      sql.bind(node_type.name.to_s, "text") << ", "
      sql.bind_text_array(node_type.labels) << ", "
      sql.bind_json(json)
      cols.each do |c, v|
        sql << ", "
        sql.bind(v, c.sql_type(@graph.connection))
      end
      sql << ")"
    end

    # The edge row and both endpoints must be visible, and the policy's
    # conditions on the stored edge must hold.
    def edge_row_condition(sql, ref, edge_type, request)
      sql << " WHERE tgt.id = "
      sql.bind(ref.id, "bigint") << " AND tgt.type = "
      sql.bind(edge_type.name.to_s, "text")
      sql << " AND s.id = tgt.source_id AND t.id = tgt.target_id AND "
      @context.append_node_visible(sql, "s")
      sql << " AND "
      @context.append_node_visible(sql, "t")
      sql << " AND "
      existing_row(sql, :edge, request)
    end

    # Visibility of the stored row "tgt" plus the policy's optional
    # conditions on it (allowed old-to-new transitions).
    def existing_row(sql, kind, request)
      kind == :node ? @context.append_node_visible(sql, "tgt") : @context.append_edge_visible(sql, "tgt")
      policy = @graph.write_policy
      return unless policy.respond_to?(:existing)

      condition = policy.existing(Arel::Table.new("tgt"), request)
      return if condition.nil?
      unless condition.is_a?(Arel::Nodes::Node) || condition.is_a?(Arel::Nodes::SqlLiteral)
        raise ConfigurationError, "write policy returned #{condition.class}, expected an Arel condition"
      end

      sql << " AND ("
      sql.arel(condition)
      sql << ")"
    end

    # properties = (old || new) - removed keys
    def set_properties(sql, current, json, removed, excluded: false)
      sql << "properties = (" << current << " || "
      excluded ? sql << "EXCLUDED.properties" : sql.bind_json(json)
      sql << ") - "
      sql.bind_text_array(removed)
      sql << ", updated_at = now()"
    end

    def set_columns(sql, cols, excluded: false)
      cols.each do |c, v|
        sql << ", " << ident(c.name) << " = "
        excluded ? sql << "EXCLUDED." << ident(c.name) : sql.bind(v, c.sql_type(@graph.connection))
      end
    end

    def null_keys(props) = props.select { |_, v| v.nil? }.keys.map(&:to_s)

    def authorize!(operation, type, target: nil, from: nil, to: nil, key: nil, properties: {}, attrs: {})
      request = WriteRequest.new(viewer: @context.viewer, operation:, type: type.to_sym, target:, from:, to:, key:,
                                 properties: properties.freeze, attrs: attrs.transform_keys(&:to_sym).freeze,
                                 trusted: @trusted)
      raise WriteRejected unless @graph.write_policy.authorize?(request) == true

      request
    end

    def trusted!(operation)
      raise NotTrusted, "#{operation} needs the trusted writer" unless @trusted
    end

    def concrete_node_type!(type)
      node_type = @graph.type.node_type!(type)
      raise ValidationError, "#{node_type.name} is abstract" if node_type.abstract?

      node_type
    end

    def encode_attrs(columns, attrs, insert:)
      attrs = (attrs || {}).transform_keys(&:to_sym)
      unknown = attrs.keys - columns.keys
      raise ValidationError, "unknown column#{"s" if unknown.size > 1} #{unknown.join(", ")}" if unknown.any?

      columns.each_value do |c|
        raise ValidationError, "#{c.name} is required" if insert && c.required? && attrs[c.name].nil?
        raise ValidationError, "#{c.name} cannot be null" if attrs.key?(c.name) && attrs[c.name].nil? && !c.null?
      end
      attrs.map { |name, v| [columns.fetch(name), v] }
    end

    # Runs a write in a savepoint, so a refusal never aborts the caller's
    # transaction. Zero rows means the statement's own checks refused it.
    def write(sql)
      id = @graph.with_connection do |c|
        c.transaction(requires_new: true) do
          c.exec_query(sql.to_s, "Pglpg", sql.binds).rows.first&.first
        end
      end
      raise WriteRejected if id.nil?

      id.to_i
    rescue ActiveRecord::StatementInvalid => e
      case e.cause
      when PG::UniqueViolation, PG::ForeignKeyViolation then raise WriteRejected
      when PG::NotNullViolation, PG::CheckViolation then raise ValidationError, e.message
      else raise
      end
    end

    def ref(kind, id) = @graph.ref(kind, id)

    def new_sql = Sql.new(@graph.connection)

    def table(name) = @graph.connection.quote_table_name(name)

    def ident(name) = @graph.connection.quote_column_name(name)
  end
end
