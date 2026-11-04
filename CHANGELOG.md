# Changelog

## 0.4.0 (2026-11-04)

### Added

- `Context#parse_match(text, params: {})` builds a lazy query from a read-only
  fixed-length GQL MATCH subset. It uses the Ruby query builder, named value
  binds, and the caller’s visibility, date mode and execution limits. Malformed
  query text and invalid parameters report located `Pglpg::ParseError` diagnostics.

## 0.3.0 (2026-11-03)

### Breaking

- Temporal-capable reads require `graph.for(viewer:, as_of: Date)` or
  `as_of: :any`; omitted/nil mode permits only node-only and statically
  timeless-only reads. Generic edge Ref lookups in graphs with temporal types
  require a mode even for missing edges. Date contexts refuse all data writes
  with `ReadOnlyContext`, including model no-op saves and trusted-writer access.
- Temporal inserts and every temporal upsert require explicit `valid_from:`
  presence (nil is unbounded); omitted update bounds preserve stored values.
  On upsert, an omitted upper bound is nil on insert and preserved on conflict.
- Enabling temporal types on existing populated tables requires
  `storage.enable_temporal!(types:, backfill: nil)` in an explicit migration.
  Reserved `valid_from`/`valid_to` names must first be removed from application
  declarations. Incompatible legacy columns require an application migration;
  timestamp values are never silently cast to dates. The helper locks the
  table and atomically installs metadata/checks plus an optional backfill.
- Complete-key lookups validate literal component values: nil, arrays and
  query conditions are refused before SQL, including on existing single/scoped
  keys. Use `match` for structured property filters.
- Adopting composite/edge keys or endpoint/property uniqueness requires
  auditing and backfilling all required components, resolving duplicates and
  running `storage.sync_constraints!` in the same application transaction.
  New caller-chosen key forms require the trusted writer; unique components
  cannot be changed and keyed edge upserts cannot rewire endpoints.
- Opting a type into `open: true` rejects duplicate String/Symbol aliases for
  declared fields as well as extras. Closed normalization is unchanged.
  Openness inherits from any open parent; local false does not close it.
  Closing/promoting declarations needs explicit data audit/backfill.

### Added

- Explicit `open: true` node and edge properties (ADR-0015), with openness
  inherited from any open node parent. Closed remains the default. Declared
  property/key checks, labels, endpoints, visibility and temporal rules remain.
- Extra properties accept strict JSON-native scalars and flat homogeneous
  scalar arrays; nil means absent/removal. Invalid names, duplicate aliases,
  metadata/application-column collisions and unsupported values are refused
  before the data statement. Open-type alias rejection includes declared
  fields; closed normalization is unchanged. Extra decoded JSON values,
  including historical map keys, are deeply frozen.
- Model `extra_properties` remains read-only and declared saves preserve
  extras. Query/filter/order/pluck still require declared properties. Openness
  adds no DDL; closing/promoting types requires explicit application auditing
  and backfill. Optional `pglpg_open_types` shared leak fixtures cover extras.

- Composite node keys and edge property keys (ADR-0014): `key :a, :b` on
  required string/integer/boolean/enum properties, with inherited node-key
  domains and exact edge-type domains. General tuples and single non-string
  keys require trusted insertion; legacy single-string generation and scoped
  node occupancy grants retain their behavior. All components are immutable.
  Unsupported edge scope declarations raise `SchemaError` explicitly.
- `Context#find_edge(type, **key)` looks up a full edge property key through
  current visibility on the edge and both endpoints, with the context's date.
  Complete-key node/edge lookups validate literal values before SQL.
- `unique: [:p, :q]` enforces a required endpoint/property tuple per edge type.
  Trusted keyed edge upsert accepts `key:` and requires unchanged endpoints;
  without a property key, upsert uses endpoint/property uniqueness. Constraints
  are cumulative and span all dates. Uniqueness properties cannot be updated.
- Composite/non-string model keys are required attributes, created through
  `save(writer:)`; generated keys remain unassignable. Composite key readers
  return frozen maps; legacy node scalar/scoped key readers stay scalar.
  Adoption requires application backfill/deduplication and transactional
  `sync_constraints!`; no automatic data migration is performed.

- Context inspection shows an explicitly selected Date or `:any` read mode.
- Opt-in `temporal: true` edge types (ADR-0013): exact Date metadata,
  half-open `[valid_from, valid_to)` intervals, nil unbounded, finite dates
  0001-01-01 through 9999-12-31. DateTime, Time and String are rejected.
- Context-wide date eligibility on direct edge reads, every pattern and
  reachability hop, models, lazy associations and eager batches, combined with
  current visibility before counts, pagination, limits and completeness.
  Timeless edges remain eligible; `:any` ignores only validity. This is valid
  time on the stored graph, not historical values or historical permissions.
- `TemporalModeRequired` and `TemporalMigrationRequired` errors. Generated
  CHECK digests track explicit temporal enablement; changed/absent or
  unvalidated checks on populated temporal types require acknowledgement.
  Omitted backfill preserves bounds, and disabling types retains columns.
- Edge values expose `temporal?`, `valid_from`, `valid_to`; temporal models
  have strict metadata attributes, explicit nil assignment tracking and bound
  pluck support. Lifetime pair uniqueness remains unchanged: gaps require
  separate non-pair-unique episode Refs; overlaps are allowed.
- Optional `pglpg_temporal` shared leak-fixture mode, and `bench/temporal.rb`
  for same-fixture reference comparisons and temporal index experiments.

### Security

- Schema constraint failures use a generic ValidationError without a database
  cause or stored-row detail. Temporal upsert argument validation is independent
  of visible, hidden or absent pair occupancy.

## 0.2.0 (2026-10-30)

### Breaking

- Symmetric edge types use `both`; `out` and `in` reject them, and `both`
  rejects directed types. After adding a symmetric type, run
  `Kg.storage.sync_constraints!` to install its canonical-endpoint constraint.
- Adopting scoped keys requires a required string scope property, both scope
  and key in lookups and trusted upserts, and a transactional backfill with
  `sync_constraints!` on the same connection. Interactive caller-chosen scoped
  keys require an explicit `key_scope_allowed` occupancy grant. Existing
  unscoped key declarations keep their contract.

### Security

- Database constraint failures on refused writes no longer expose the original
  database exception through `Exception#cause`, including unscoped writes.

### Added

- Scoped keys (ADR-0012): `key :uid, scope: :namespace` enforces a required
  string namespace/key pair across the declaring type and subtypes. Interactive
  caller-chosen keys require an explicit `key_scope_allowed` grant to learn
  occupancy within that graph/domain/scope, including hidden collisions. The
  grant gives no row access and has no SQL-time revocation guarantee. Trusted
  upserts and `find_node` require both parts; scope and key remain immutable.
  Existing schemas require a transactional backfill and constraint migration.

- Add `with_associations` to model relations for batched, visibility-aware eager loading (ADR-0011). Preloaded associations are materialized reads and can become stale; reload, save, or destroy clears that instance's cache. Each batch uses a separate database snapshot and raises `TooManyRows` when its distinct owner–target pairs exceed `max_rows`.

- Model layer, reads (ADR-0010; `require "pglpg/model"`):
  - `Pglpg::Model::Node` and `Pglpg::Model::Edge` are ActiveModel classes
    bound to a graph and a schema type with `graph Kg, type: :Person`. Their
    attributes are the type's properties and the graph's application
    columns. Assignment is strict: no form coercion.
  - Declaring a model rejects a second model for the same type (a class of
    the same name replaces it, for code reloading), a property named like an
    application column or a model method, and a model extending another
    model off the schema's inheritance.
  - `Model.in(ctx)` returns a `Pglpg::Model::Relation` with `where`, `order`,
    `limit`, `offset`, `count`, `exists?`, `first` and `find_by`. It compiles
    to a `Pglpg::Query`, so visibility, ordering, `max_rows` and timeouts
    apply as there. Edge relations return each symmetric edge once.
  - `Relation#find(ref)` takes a `Ref` or its String form and raises
    `Pglpg::Model::RecordNotFound` for a missing, hidden or wrong-type
    element alike.
  - A node loads as the model registered for its concrete type, else as the
    queried model; `schema_type` names the stored type and
    `extra_properties` holds properties the model doesn't declare.
  - The shared leak suite observes models, relations and `find`.
- Model layer, writes (ADR-0010):
  - `Relation#new` / `#build`, `#create` and `#create!` build records bound
    to the relation's context. Edge records take `source:` and `target:` (a
    node Ref or model); they can't change once stored.
  - `save` / `save!` validate, then insert a new record or update only its
    changed attributes through the context's guarded write API. `save`
    returns false on validation errors; `save!` raises
    `Pglpg::Model::RecordInvalid`. Refusals, timeouts and database errors
    raise, and changes survive any failure. Without changes, no statement
    runs.
  - Schema validations: property values, required properties and required
    columns. Keys are generated: an assigned key is an error on create, a
    changed key on update. Abstract types can't be created.
  - `save(writer:)` and `destroy(writer:)` accept only the record's own
    context's trusted writer (`ArgumentError` otherwise), for trusted-only
    writes such as pair-unique edges; it never permits assigning a key.
  - `destroy` deletes an edge, or a node through the trusted writer only;
    `destroyed?`.
  - `reload` replaces attributes, timestamps and the dirty baseline, and
    raises `RecordNotFound` without changing the record when the element
    is missing or hidden.
  - After a create, generated keys and timestamps are unknown until
    `reload`. A caller's rollback is not tracked.
- Model layer, associations (ADR-0010 §5):
  - `has_many name, :out | :in | :both, edge:, label: nil, model: nil` on a
    node model defines a method returning a `Pglpg::Model::AssociationRelation`.
    `:both` is for symmetric types, `:out` / `:in` for directed ones. The
    target label defaults to the edge type's other endpoint and the model to
    the one registered for it. Declaring checks the direction, that the
    owner can be an endpoint, and name clashes; associations are inherited.
  - A target query returns each visible target once: duplicates are removed
    before `order`, `limit`, `offset`, `count` and `exists?`. `rel_where`
    filters on edge properties ("at least one matching visible edge");
    `rel_order` raises there.
  - `with_rel` returns a `Pglpg::Model::BindingRelation`: one
    `[target, edge]` pair per matching edge, counted and paginated as pairs,
    with `rel_order`. It must come before `order`, `limit` or `offset`.
    `each_with_rel` enumerates it. Edges load as the registered edge model.
  - Associations need a saved owner, start from it (so its visibility
    applies) and can't build records yet.
  - The shared leak suite observes every association of every visible owner:
    targets, counts, `exists?`, `first`, pagination, `rel_where` and pairs.
- Model layer, `pluck` (ADR-0010 §5):
  - `Relation#pluck(*names)` returns attribute values (or `:id`, `:ref`) per
    element, in the relation's order: a value for one name, an Array for
    several. Elements are chosen first and projected afterwards, so two
    targets with equal values give two values.
  - `BindingRelation#pluck(*names, rel: [])` gives one entry per pair:
    the target's names, then the edge's `rel` names.
  - Unknown names raise `ArgumentError` before any query runs; `max_rows`
    applies as for `to_a`.
  - The shared leak suite also observes `pluck` on relations, associations
    and pairs.
- `Context#reachable(from:, via:, max_depth:, max_nodes:, direction: :out, deadline: nil)`
  returns a `Pglpg::Reachability`: visible nodes with their minimum depth,
  ordered by depth then id, plus `complete` and `stopped_at_depth`.
  - Runs as one recursive CTE that computes one BFS level per step (ADR-0009),
    so it sees one snapshot at any isolation level.
  - The start node is never returned; a hidden start and a missing one give
    the same empty, complete result.
  - `direction:` follows the `match` rule from ADR-0008, and a `via` list may
    not mix directed and symmetric types.
  - `max_nodes` may not exceed `max_rows`. `deadline` (seconds) can only
    shorten the configured `statement_timeout`.
  - The shared leak suite observes `reachable` from every visible node.
- `Context#read` takes a `timeout:` in milliseconds (internal), and every read
  now runs in a savepoint, also with `statement_timeout: nil`. A timeout set
  by the session itself no longer leaves the caller's transaction aborted.
- The shared leak suite keeps its `reachable` budgets within `max_rows`.
- The benchmark is rebuilt for CI (task 36367): seeded, versioned 1m,
  hub-heavy and 10m fixtures with a manifest. Its cells cover viewers L2 and
  L4, with starts each viewer can see, and include `reachable`. It gates
  per-cell bounds in `bench/bounds.yml`, and compares buffers and latency
  with a baseline revision. Buffers come from JSON plans and fail closed, and
  a self-test proves that the gate fails. `bench/run.rb` is replaced by
  `bench/measure.rb` and `bench/gate.rb`. A new `bench.yml` workflow runs the
  full fixtures. The CI benchmark step no longer hides a failure behind
  `tee`.
- Symmetric edge types (ADR-0008): `edge name, from:, to:, symmetric: true`,
  with `allow_self_loops: true` to permit self-loops (off by default).
  - Each edge is stored once with `source_id < target_id` (`<=` with self-loops),
    enforced by a generated `CHECK`; `sync_constraints!` adds it. Writes accept
    the endpoints in either order, and `WriteRequest#from` / `#to` carry the
    canonical order. `unique: :pair` covers the unordered pair.
  - One endpoint carries `from` and the other `to`, in either order.
  - `Query#both` follows a symmetric edge from either end (GQL `~[ ]~`). With
    no endpoint fixed, each edge binds once per orientation (once for a
    self-loop); use `return(:edge).distinct` to list edges once.
  - **Breaking:** `out` and `in` raise `ArgumentError` for symmetric types, and
    `both` raises it for directed types. `symmetric:` no longer raises
    `SchemaError`.
  - `Edge#symmetric?` and `Edge#other(ref)`.
  - The shared leak suite adds symmetric cases: hidden bridges and hidden
    nodes stored at either end of an edge.
- The benchmark adds symmetric 1- and 2-hop shapes and checks the buffers of
  the symmetric hub query.

### Fixed

- Storage DDL is atomic: `sync_constraints!` and the entire `create!` operation
  use a transaction on their supplied connection, or a savepoint in an existing
  ActiveRecord transaction. A failed call restores its DDL and leaves a healthy
  caller transaction usable. Outside a transaction, each call commits its own
  transaction. Application backfills still need an explicit outer transaction
  on the same connection to be rolled back with a failed schema transition.


## 0.1.0 (2026-10-28)

First version, following the accepted 0.1 baseline (knowen.md bb topic 145).
Requires Ruby ≥ 4.0, ActiveRecord ≥ 8.1 and PostgreSQL ≥ 18.

- Graph type DSL: node types with inheritance and abstract types, edge types,
  typed properties (closed types), one string key per type, `unique: :pair`
  edge types, application columns.
- Storage: two tables per graph, generated constraints (endpoint foreign keys
  with `ON DELETE RESTRICT`, keys unique across a type and its subtypes, pair
  uniqueness, typed required-property checks), `sync_constraints!`,
  `label_drift` and `relabel!`.
- `Pglpg::Ref`: immutable, graph-scoped element references.
- `Graph#for(viewer:)` as the only entry point.
- Writes: interactive inserts with generated keys, updates and edge deletes;
  a trusted writer (granted by the application) for caller-chosen keys,
  upserts and node deletes. The write policy checks the request in Ruby;
  visibility and the policy's conditions on the stored row run inside the
  statement; edge endpoints are checked and locked `FOR SHARE`.
- Fixed-length pattern queries with structured conditions, ordering,
  pagination, `count`, `exists?`, `first`, `distinct` and typed results.
- Shared leak specs (`it_behaves_like "a pglpg visibility policy"`).
- Benchmark harness with time and buffer limits.
