# Changelog

## Unreleased

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
