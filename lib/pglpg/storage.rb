# frozen_string_literal: true

require "digest"

module Pglpg
  # The two tables of a graph, their indexes and the constraints generated
  # from the graph type.
  #
  #   Kg.storage.create!          # in a migration: tables, indexes, constraints
  #   Kg.storage.sync_constraints! # after a graph type change
  #   Kg.storage.relabel!         # after inherited labels change
  #   Kg.storage.label_drift      # => {} when stored labels match the schema
  class Storage
    NAME_LIMIT = 63
    MIN_SERVER_VERSION = 180_000

    attr_reader :graph, :nodes_table, :edges_table

    def initialize(graph, nodes_table:, edges_table:)
      @graph = graph
      @nodes_table = nodes_table.to_s
      @edges_table = edges_table.to_s
    end

    def create!(connection = graph.connection)
      if connection.database_version < MIN_SERVER_VERSION
        raise ConfigurationError, "pglpg needs PostgreSQL 18 or later"
      end

      tables_sql(connection).each { connection.execute(_1) }
      sync_constraints!(connection)
    end

    def drop!(connection = graph.connection)
      connection.execute("DROP TABLE IF EXISTS #{q(connection, edges_table)}, #{q(connection, nodes_table)}")
    end

    def tables_sql(connection = graph.connection)
      n = q(connection, nodes_table)
      e = q(connection, edges_table)
      [
        <<~SQL,
          CREATE TABLE #{n} (
            id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            key_label text NOT NULL,
            labels text[] NOT NULL,
            properties jsonb NOT NULL DEFAULT '{}',
            #{columns_sql(connection, type.node_columns)}created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now(),
            CHECK (labels @> ARRAY[key_label]),
            CHECK (jsonb_typeof(properties) = 'object')
          )
        SQL
        <<~SQL,
          CREATE TABLE #{e} (
            id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            type text NOT NULL,
            source_id bigint NOT NULL REFERENCES #{n} (id) ON DELETE RESTRICT,
            target_id bigint NOT NULL REFERENCES #{n} (id) ON DELETE RESTRICT,
            properties jsonb NOT NULL DEFAULT '{}',
            #{columns_sql(connection, type.edge_columns)}created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now(),
            CHECK (jsonb_typeof(properties) = 'object')
          )
        SQL
        "CREATE INDEX #{q(connection, "#{nodes_table}_labels")} ON #{n} USING gin (labels)",
        "CREATE INDEX #{q(connection, "#{nodes_table}_properties")} ON #{n} USING gin (properties jsonb_path_ops)",
        "CREATE INDEX #{q(connection, "#{edges_table}_source")} ON #{e} (source_id, type) INCLUDE (#{covering(connection, "target_id")})",
        "CREATE INDEX #{q(connection, "#{edges_table}_target")} ON #{e} (target_id, type) INCLUDE (#{covering(connection, "source_id")})",
        "CREATE INDEX #{q(connection, "#{edges_table}_properties")} ON #{e} USING gin (properties jsonb_path_ops)"
      ]
    end

    # The constraints the graph type requires, by name. Names carry a digest
    # of the definition, so a changed definition gets a new name.
    def constraints(connection = graph.connection)
      list = []
      n = q(connection, nodes_table)
      e = q(connection, edges_table)

      type.node_types.each_value do |t|
        has_label = "labels @> ARRAY[#{connection.quote(t.name.to_s)}]::text[]"
        if (key = t.own_key)
          list << [:index, nodes_table, "key_#{t.name}_#{key.property}",
                   "ON #{n} ((properties->>#{connection.quote(key.property.to_s)})) WHERE #{has_label}"]
        end
        t.own_properties.each_value.select(&:required?).each do |p|
          list << [:check, nodes_table, "req_#{t.name}_#{p.name}", "NOT (#{has_label}) OR #{typed_check(connection, p)}"]
        end
      end

      type.edge_types.each_value do |t|
        is_type = "type = #{connection.quote(t.name.to_s)}"
        list << [:index, edges_table, "pair_#{t.name}", "ON #{e} (source_id, target_id) WHERE #{is_type}"] if t.unique_pair?
        if t.symmetric?
          # Canonical orientation, so a pair is stored one way only (ADR-0008).
          list << [:check, edges_table, "sym_#{t.name}",
                   "NOT (#{is_type}) OR source_id #{t.allow_self_loops? ? "<=" : "<"} target_id"]
        end
        t.own_properties.each_value.select(&:required?).each do |p|
          list << [:check, edges_table, "req_#{t.name}_#{p.name}", "NOT (#{is_type}) OR #{typed_check(connection, p)}"]
        end
      end

      list.to_h do |kind, table, label, body|
        name = constraint_name(table, label, body)
        sql = if kind == :index
                "CREATE UNIQUE INDEX #{q(connection, name)} #{body}"
              else
                "ALTER TABLE #{q(connection, table)} ADD CONSTRAINT #{q(connection, name)} CHECK (#{body})"
              end
        [name, { kind:, table:, sql: }]
      end
    end

    # Adds missing generated constraints and drops stale ones.
    def sync_constraints!(connection = graph.connection)
      wanted = constraints(connection)
      existing = existing_constraints(connection)
      (existing.keys - wanted.keys).each do |name|
        info = existing[name]
        if info[:kind] == :index
          connection.execute("DROP INDEX #{q(connection, name)}")
        else
          connection.execute("ALTER TABLE #{q(connection, info[:table])} DROP CONSTRAINT #{q(connection, name)}")
        end
      end
      (wanted.keys - existing.keys).each { connection.execute(wanted[_1][:sql]) }
      nil
    end

    # Rewrites stored label sets to match the graph type.
    def relabel!(connection = graph.connection)
      return 0 if concrete_types.empty?

      connection.exec_update(<<~SQL, "Pglpg relabel")
        UPDATE #{q(connection, nodes_table)} AS n SET labels = v.labels
        FROM (VALUES #{label_values(connection)}) AS v(key_label, labels)
        WHERE n.key_label = v.key_label AND n.labels IS DISTINCT FROM v.labels
      SQL
    end

    # Stored nodes whose labels disagree with the graph type, counted by key
    # label. Rows of unknown or abstract types count as drift too.
    def label_drift(connection = graph.connection)
      values = concrete_types.empty? ? "SELECT NULL::text, NULL::text[] WHERE false" : "VALUES #{label_values(connection)}"
      connection.select_rows(<<~SQL, "Pglpg label drift").to_h { |label, count| [label.to_sym, count.to_i] }
        SELECT n.key_label, count(*) FROM #{q(connection, nodes_table)} AS n
        LEFT JOIN (#{values}) AS v(key_label, labels) ON v.key_label = n.key_label
        WHERE v.labels IS NULL OR n.labels IS DISTINCT FROM v.labels
        GROUP BY n.key_label ORDER BY n.key_label
      SQL
    end

    private

    def type = graph.type

    def q(connection, name) = connection.quote_table_name(name)

    def concrete_types = type.node_types.values.reject(&:abstract?)

    def label_values(connection)
      concrete_types.map do |t|
        "(#{connection.quote(t.name.to_s)}, ARRAY[#{t.labels.map { connection.quote(_1) }.join(", ")}]::text[])"
      end.join(", ")
    end

    # Edge columns declared covering: true (typically what the visibility
    # policy filters on) ride along in the traversal indexes.
    def covering(connection, endpoint)
      [endpoint, *type.edge_columns.each_value.select(&:covering?).map { connection.quote_column_name(_1.name) }].join(", ")
    end

    def columns_sql(connection, columns)
      columns.each_value.map do |c|
        sql = +"#{connection.quote_column_name(c.name)} #{c.sql_type(connection)}"
        sql << " NOT NULL" unless c.null?
        sql << " DEFAULT #{connection.quote(c.options[:default])}" if c.default?
        "#{sql},\n  "
      end.join
    end

    # Rejects a missing key, JSON null and the wrong JSON type: a CHECK passes
    # on NULL, so the comparison is wrapped in IS TRUE.
    def typed_check(connection, prop)
      "(jsonb_typeof(properties->#{connection.quote(prop.name.to_s)}) = #{connection.quote(prop.json_type)}) IS TRUE"
    end

    def constraint_name(table, label, body)
      digest = Digest::SHA256.hexdigest(body)[0, 8]
      base = "pglpg_#{table}_#{label}"
      base = base[0, NAME_LIMIT - digest.size - 1]
      "#{base}_#{digest}"
    end

    def existing_constraints(connection)
      prefixes = [nodes_table, edges_table].map { "pglpg\\_#{_1.gsub("_", "\\_")}\\_%" }
      rows = connection.select_rows(<<~SQL, "Pglpg constraints")
        SELECT c.conname, 'check', t.relname FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname IN (#{connection.quote(nodes_table)}, #{connection.quote(edges_table)})
          AND t.relnamespace = to_regnamespace(current_schema())
          AND (c.conname LIKE #{connection.quote(prefixes[0])} OR c.conname LIKE #{connection.quote(prefixes[1])})
        UNION ALL
        SELECT i.indexname, 'index', i.tablename FROM pg_indexes i
        WHERE i.tablename IN (#{connection.quote(nodes_table)}, #{connection.quote(edges_table)})
          AND i.schemaname = current_schema()
          AND (i.indexname LIKE #{connection.quote(prefixes[0])} OR i.indexname LIKE #{connection.quote(prefixes[1])})
      SQL
      rows.to_h { |name, kind, table| [name, { kind: kind.to_sym, table: }] }
    end
  end
end
