# Changelog

## Unreleased

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
