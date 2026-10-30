# Changelog

## Unreleased

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
