# Changelog

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
