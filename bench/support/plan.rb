# frozen_string_literal: true

require "json"

# Captures the one statement a public pglpg call runs, and measures it with
# EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON). Capturing the SQL, rather than
# asking pglpg for it, works the same for every revision measured.
module Plan
  class Error < StandardError; end

  Statement = Data.define(:sql, :binds)

  module_function

  # The statement pglpg ran inside the block. pglpg names its reads "Pglpg";
  # a call that runs any other number of them is an error, not a sample.
  def capture(&)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << Statement.new(payload[:sql], payload[:binds]) if payload[:name] == "Pglpg"
    end
    result = yield
    raise Error, "expected 1 pglpg statement, got #{statements.size}" unless statements.size == 1

    [statements.first, result]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # The parsed JSON plan of +statement+, run under ANALYZE.
  def explain(conn, statement)
    raw = conn.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.sql}", "bench", statement.binds)
    raw.is_a?(String) ? JSON.parse(raw) : raw
  end

  def explain_text(conn, statement)
    conn.select_values("EXPLAIN (ANALYZE, BUFFERS) #{statement.sql}", "bench", statement.binds)
  end

  # Shared buffers (hit + read) of the top plan node, which include its
  # children. Fails closed: a missing or non-numeric value raises.
  def buffers(plan)
    top = plan.is_a?(Array) && plan.first.is_a?(Hash) ? plan.first["Plan"] : nil
    raise Error, "plan has no top node" unless top.is_a?(Hash)

    ["Shared Hit Blocks", "Shared Read Blocks"].sum do |key|
      value = top[key]
      raise Error, "plan has no #{key.inspect}" unless value.is_a?(Integer)

      value
    end
  end
end
