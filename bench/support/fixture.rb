# frozen_string_literal: true

require "digest"
require "json"

# Seeded, versioned synthetic graphs. A loaded database carries a manifest
# (bench_manifest), and is used only when the manifest matches the requested
# fixture and the storage schema of the pglpg revision being measured.
module Fixture
  # Bump when the generator changes what it loads.
  GENERATOR_VERSION = 3
  SEED = 0.42
  MANIFEST = "bench_manifest"

  # Edge counts at scale 1 sum to 1M (FRIEND loses the few self pairs).
  BASE = {
    persons: 120_000, incidents: 50_000, locations: 20_000, orgs: 10_000,
    knows: 330_000, involved: 250_000, member: 200_000, friend: 170_000
  }.freeze

  # hubs: extra Person hubs with fixed degrees, on top of the skewed sources.
  HUB = { knows: 5_000, friend: 2_000, involved: 1_000 }.freeze
  FIXTURES = {
    "ci" => { scale: 0.2, hubs: 0 },
    "1m" => { scale: 1.0, hubs: 0 },
    "hub-heavy" => { scale: 1.0, hubs: 20 },
    "10m" => { scale: 10.0, hubs: 0 }
  }.freeze

  LEVEL = "width_bucket(random(), ARRAY[0, 0.7, 0.85, 0.95]::float8[])" # 70% L1, 15% L2, 10% L3, 5% L4

  module_function

  def spec!(name)
    FIXTURES.fetch(name) { raise ArgumentError, "unknown fixture #{name.inspect} (#{FIXTURES.keys.join(", ")})" }
  end

  def counts(name)
    spec = spec!(name)
    BASE.transform_values { (_1 * spec[:scale]).round }
  end

  # Ids of the extra hubs: evenly spread Person ids, away from the skewed low
  # ids. Their classification cycles 1..4, so every clearance sees some.
  def hub_ids(name)
    hubs = spec!(name)[:hubs]
    persons = counts(name)[:persons]
    (1..hubs).map { _1 * (persons / (hubs + 1)) }
  end

  def wanted(name, graph)
    spec = spec!(name)
    { "generator_version" => GENERATOR_VERSION, "seed" => SEED, "fixture" => name,
      "scale" => spec[:scale], "hubs" => spec[:hubs], "storage" => storage_fingerprint(graph) }
  end

  # The schema pglpg would create for this graph: tables, indexes and
  # generated constraints. A baseline whose storage differs can't share the
  # candidate's fixture.
  def storage_fingerprint(graph)
    storage = graph.storage
    Digest::SHA256.hexdigest([*storage.tables_sql, *storage.constraints.keys.sort].join("\n"))[0, 16]
  end

  def manifest(conn)
    return nil unless conn.table_exists?(MANIFEST)

    raw = conn.select_value("SELECT value FROM #{MANIFEST} WHERE key = 'fixture'")
    raw && JSON.parse(raw)
  end

  # nil when the database holds the wanted fixture, or the reason it doesn't.
  def mismatch(conn, name, graph)
    found = manifest(conn) or return "no fixture manifest"
    want = wanted(name, graph)
    diff = want.keys.reject { found[_1] == want[_1] }
    diff.empty? ? nil : "manifest differs in #{diff.join(", ")}: #{diff.to_h { [_1, found[_1]] }}"
  end

  def load!(conn, name, graph)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    c = counts(name)
    n = graph.nodes_table
    e = graph.edges_table
    conn.execute("DROP TABLE IF EXISTS #{MANIFEST}")
    storage = graph.storage
    storage.drop!
    # Tables first, indexes and constraints after the inserts: building them
    # once is much faster than maintaining them row by row at 10M edges.
    tables, indexes = storage.tables_sql.partition { _1.lstrip.start_with?("CREATE TABLE") }
    raise "expected 2 CREATE TABLE statements from Storage#tables_sql" unless tables.size == 2

    tables.each { conn.execute(_1) }
    conn.execute("SET maintenance_work_mem = '512MB'")
    p_last = c[:persons]
    i_first = p_last + 1
    i_last = p_last + c[:incidents]
    l_first = i_last + 1
    o_first = l_first + c[:locations]
    # One session and no parallel inserts, so setseed makes every random()
    # below, and so every id, the same on every load.
    conn.execute("SELECT setseed(#{SEED})")
    [
      "INSERT INTO #{n} (key_label, labels, properties, classification)
       SELECT 'Person', '{Person}', jsonb_build_object('uid', 'P' || g, 'name', 'person ' || g), #{LEVEL}
       FROM generate_series(1, #{c[:persons]}) g",
      "INSERT INTO #{n} (key_label, labels, properties, classification)
       SELECT 'Incident', '{Incident}', jsonb_build_object('severity', 1 + (g % 5)), #{LEVEL}
       FROM generate_series(1, #{c[:incidents]}) g",
      "INSERT INTO #{n} (key_label, labels, properties, classification)
       SELECT 'Location', '{Location}', jsonb_build_object('name', 'loc ' || g), #{LEVEL}
       FROM generate_series(1, #{c[:locations]}) g",
      "INSERT INTO #{n} (key_label, labels, properties, classification)
       SELECT 'Organization', '{Organization}', jsonb_build_object('name', 'org ' || g), #{LEVEL}
       FROM generate_series(1, #{c[:orgs]}) g",
      # Skewed sources (random()^2) create hubs: id k gets about
      # count / sqrt(k * persons) edges, so id 1 about count / sqrt(persons).
      "INSERT INTO #{e} (type, source_id, target_id, classification)
       SELECT 'KNOWS', 1 + floor(random()^2 * #{p_last})::bigint, 1 + floor(random() * #{p_last})::bigint, #{LEVEL}
       FROM generate_series(1, #{c[:knows]})",
      "INSERT INTO #{e} (type, source_id, target_id, classification)
       SELECT 'INVOLVED_IN', 1 + floor(random()^2 * #{p_last})::bigint,
              #{i_first} + floor(random() * #{c[:incidents]})::bigint, #{LEVEL}
       FROM generate_series(1, #{c[:involved]})",
      "INSERT INTO #{e} (type, source_id, target_id, classification)
       SELECT 'OCCURRED_AT', g, #{l_first} + floor(random() * #{c[:locations]})::bigint, #{LEVEL}
       FROM generate_series(#{i_first}, #{i_last}) g",
      "INSERT INTO #{e} (type, source_id, target_id, classification)
       SELECT 'MEMBER_OF', 1 + floor(random()^2 * #{p_last})::bigint,
              #{o_first} + floor(random() * #{c[:orgs]})::bigint, #{LEVEL}
       FROM generate_series(1, #{c[:member]})",
      # Symmetric: stored once per pair, smaller id first (ADR-0008).
      "INSERT INTO #{e} (type, source_id, target_id, classification)
       SELECT 'FRIEND', least(a, b), greatest(a, b), #{LEVEL}
       FROM (SELECT 1 + floor(random()^2 * #{p_last})::bigint AS a, 1 + floor(random() * #{p_last})::bigint AS b
             FROM generate_series(1, #{c[:friend]})) x
       WHERE a <> b",
      *hub_sql(name, n, e, p_last, i_first, c),
      *indexes
    ].each { conn.execute(_1) }
    storage.sync_constraints!
    # ANALYZE samples 300 × the largest column statistics target rows at
    # random, and computes each column's statistics at that column's own
    # target. A target of 10000 on updated_at, which no query reads, makes
    # the sample 3M rows: on tables up to 3M rows ANALYZE reads them all, so
    # the statistics and plans are the same on every load. Every other
    # column keeps the default target, so planning costs what it would in
    # production (a 10000 target everywhere made each hub query plan for
    # over 100 ms). The 10m edges table is larger and stays sampled.
    [n, e].each { conn.execute("ALTER TABLE #{_1} ALTER COLUMN updated_at SET STATISTICS 10000") }
    conn.execute("ANALYZE #{n}")
    conn.execute("ANALYZE #{e}")
    stats = stats(conn, name, graph)
    record = wanted(name, graph).merge("counts" => stats, "load_seconds" =>
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1))
    conn.execute("CREATE TABLE #{MANIFEST} (key text PRIMARY KEY, value jsonb NOT NULL)")
    conn.exec_insert("INSERT INTO #{MANIFEST} VALUES ('fixture', $1)", "bench",
                     [ActiveRecord::Relation::QueryAttribute.new("", JSON.generate(record), ActiveModel::Type::Value.new)])
    record
  end

  def hub_sql(name, n, e, p_last, i_first, c)
    hub_ids(name).each_with_index.flat_map do |id, i|
      [
        "UPDATE #{n} SET classification = #{(i % 4) + 1} WHERE id = #{id}",
        "INSERT INTO #{e} (type, source_id, target_id, classification)
         SELECT 'KNOWS', #{id}, 1 + floor(random() * #{p_last})::bigint, #{LEVEL} FROM generate_series(1, #{HUB[:knows]})",
        "INSERT INTO #{e} (type, source_id, target_id, classification)
         SELECT 'FRIEND', least(#{id}, b), greatest(#{id}, b), #{LEVEL}
         FROM (SELECT 1 + floor(random() * #{p_last})::bigint AS b FROM generate_series(1, #{HUB[:friend]})) x
         WHERE b <> #{id}",
        "INSERT INTO #{e} (type, source_id, target_id, classification)
         SELECT 'INVOLVED_IN', #{id}, #{i_first} + floor(random() * #{c[:incidents]})::bigint, #{LEVEL}
         FROM generate_series(1, #{HUB[:involved]})"
      ]
    end
  end

  def stats(conn, _name, graph)
    n = graph.nodes_table
    e = graph.edges_table
    {
      "nodes" => conn.select_rows("SELECT key_label, count(*) FROM #{n} GROUP BY 1 ORDER BY 1").to_h { [_1, _2.to_i] },
      "edges" => conn.select_rows("SELECT type, count(*) FROM #{e} GROUP BY 1 ORDER BY 1").to_h { [_1, _2.to_i] },
      "top_knows_out_degree" =>
        conn.select_value("SELECT count(*) FROM #{e} WHERE type = 'KNOWS' GROUP BY source_id ORDER BY 1 DESC LIMIT 1").to_i
    }
  end

  # Raises unless the loaded data has the shape the fixture promises.
  def sanity!(stats, name)
    c = counts(name)
    hubs = spec!(name)[:hubs]
    errors = []
    expect = lambda do |what, actual, range|
      errors << "#{what}: #{actual} not in #{range.min.round}..#{range.max.round}" unless range.cover?(actual)
    end
    { "Person" => c[:persons], "Incident" => c[:incidents], "Location" => c[:locations], "Organization" => c[:orgs] }
      .each { |label, want| expect.("#{label} nodes", stats["nodes"][label].to_i, want..want) }
    edges = stats["edges"]
    exact = { "KNOWS" => c[:knows] + (hubs * HUB[:knows]), "INVOLVED_IN" => c[:involved] + (hubs * HUB[:involved]),
              "OCCURRED_AT" => c[:incidents], "MEMBER_OF" => c[:member] }
    exact.each { |type, want| expect.("#{type} edges", edges[type].to_i, want..want) }
    friend = c[:friend] + (hubs * HUB[:friend])
    expect.("FRIEND edges", edges["FRIEND"].to_i, (friend * 0.995)..friend)
    natural = c[:knows] / Math.sqrt(c[:persons])
    top = hubs.positive? ? HUB[:knows]..(HUB[:knows] + (2 * natural)) : (0.75 * natural)..(1.25 * natural)
    expect.("top KNOWS out-degree", stats["top_knows_out_degree"], top)
    raise "fixture #{name} failed its sanity checks:\n  #{errors.join("\n  ")}" if errors.any?
  end
end
