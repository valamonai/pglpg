# pglpg

Labeled property graphs stored in plain PostgreSQL tables, for Ruby.

pglpg follows the ISO GQL property graph model and PG-Schema / PG-Keys. It
needs no PostgreSQL extension and no second database: each graph is two
ordinary tables, written inside your own transactions. Every query applies
your visibility policy to every node and edge on every hop, so hidden records
never act as bridges and never show up in counts or limits.

Status: **0.3.0 release candidate; not yet published.** The latest published
version is 0.2.0. This candidate includes temporal edges, composite/edge keys
and explicit open properties. The design and its decisions live in the
[pglpg.md](https://knowen.md/nodes/36325) knowledge base. Requires Ruby ≥ 4.0,
ActiveRecord ≥ 8.1 and PostgreSQL ≥ 18: the versions CI tests.

## Install

After 0.3.0 publication:

```ruby
gem "pglpg", "~> 0.3.0"
```

Before 1.0, minor releases may break compatibility. Read the
[0.3.0 upgrade notes](CHANGELOG.md) and the migration steps below before
upgrading from 0.2. Applications still on 0.1 must also apply the 0.2 notes.

## Upgrade from 0.2

- Choose `as_of: Date` for dated reads or `as_of: :any` for all dates.
  Omitted mode permits node-only/timeless-only reads; generic edge Ref lookup
  needs a mode whenever the graph declares a temporal edge type. Dated
  contexts are read-only, including model saves and trusted-writer access.
- Temporal inserts and every upsert require explicit `valid_from:` (nil means
  unbounded). Update omissions preserve bounds; an upsert's omitted upper
  bound is nil on insert and preserved on conflict.
- Before enabling temporal traffic on existing tables, finish an explicit
  `enable_temporal!` migration. Remove conflicting application declarations,
  audit legacy timestamps and `valid_until` boundaries, and convert them in
  application migrations without silent truncation. Keep reads/writes disabled
  during a deploy-then-migrate window. Retained temporal columns make every
  constraint sync take an edge-table `ACCESS EXCLUSIVE` lock until outer commit;
  schedule short migration transactions.
- Adopt new key/uniqueness declarations with an explicit same-connection
  transaction: backfill required components, resolve duplicates, then call
  `sync_constraints!`. Composite/non-string keys and endpoint-unique edges
  require trusted creation. Unique properties are immutable; keyed edge upsert
  cannot rewire endpoints. Legacy single-string generation/scoped grants and
  lifetime pair uniqueness retain their rules. Complete-key lookups take
  literal values; use `match` for condition/array filters.
- `open: true` is optional and changes no DDL. It rejects duplicate aliases across all
  submitted properties, reserves structural/validity names even on other
  element kinds/timeless graphs, and inherits from any open parent. Audit data
  before closing a type or promoting extras to declarations. Queries and model
  attributes still require declared properties; low-level writes and model
  reload manage extras.

Existing timeless, closed schemas with unchanged keys need no migration solely
for the version bump. Rerun your real-policy leak suite and label-drift checks
when adopting this minor release.

This candidate implements a documented standards subset: key components are
string/integer/boolean/enum, open extras are scalars/flat homogeneous lists,
and temporal validity is one date interval with current authorization. It does
not add alternate/overlap keys, open labels, dynamic query/model attributes,
chained model associations or a GQL parser. Production-like acceptance remains
separate pre-1.0 work; ordinary checks do not establish managed-plan capacity.

## Define a graph

```ruby
Kg = Pglpg::Graph.define(:kg) do
  # Application columns: real, indexed columns your policies filter on.
  column :classification, :integer, null: false, covering: true

  node :Person do
    property :uid, :string, required: true
    property :name, :string
    property :born, :date
    key :uid                       # unique across Person and its subtypes
  end
  node :Employee, extends: :Person # labels {Employee, Person}
  node :Project do
    property :uid, :string, required: true
    property :headcount, :integer
    key :uid, generate: ->(_type) { "PRJ-#{SecureRandom.hex(6)}" }
  end

  edge :WORKS_ON, from: :Person, to: :Project, unique: :pair do
    property :role, :string
  end
  edge :KNOWS, from: :Person, to: :Person
  edge :FRIEND, from: :Person, to: :Person, symmetric: true  # undirected
end
```

A `symmetric: true` edge type is undirected: each edge is stored once, smaller
node id first, and writes accept the endpoints in either order. Self-loops are
refused unless the type sets `allow_self_loops: true`.

Property types: `string integer float decimal boolean date datetime enum list`
(`enum` takes `values:`, `list` takes `of:`). Types are closed by default: undeclared
properties are rejected unless the type opts into open properties. A nil value means the property is absent.

In a migration:

```ruby
def up   = Kg.storage.create!            # tables, indexes, constraints
def down = Kg.storage.drop!
# After changing the graph type:
Kg.storage.sync_constraints!
Kg.storage.relabel!                      # when inherited labels changed
```

`Kg.storage.label_drift` returns `{}` when stored labels match the schema;
put it in a spec.

## Policies

```ruby
Pglpg.configure do |c|
  c.visibility = ClearancePolicy        # required for reads
  c.write_policy = ClearanceWritePolicy # required for writes
  c.trusted_writer_allowed = ->(ctx) { ctx.viewer.importer? } # off when unset
end

module ClearancePolicy                  # Arel conditions, applied to every alias
  def self.node(table, viewer) = table[:classification].lteq(viewer.clearance)
  def self.edge(table, viewer) = table[:classification].lteq(viewer.clearance)
end

module ClearanceWritePolicy
  # The requested operation and new state (a Pglpg::WriteRequest).
  def self.authorize?(req) = req.attrs.fetch(:classification, 0) <= req.viewer.clearance

  # Optional: a condition on the stored row, checked inside the statement
  # (for example, allowed old -> new transitions).
  def self.existing(table, req) = nil
end
```

Policies can also be passed per graph to `Graph.define`.

## Write

```ruby
g = Kg.for(viewer: current_viewer)

ann = g.insert_node(:Person, properties: { name: "Ann" }, attrs: { classification: 1 })
# => #<Pglpg::Ref kg:node:1>   (uid is generated; passing one raises ArgumentError)
g.update_node(ann, properties: { born: Date.new(1990, 1, 1) })
g.insert_edge(:KNOWS, from: ann, to: bob, attrs: { classification: 1 })

w = g.trusted_writer                    # raises NotTrusted unless granted
p = w.upsert_node(:Person, key: { uid: "PER-12" }, properties: { name: "Bob" }, attrs: { classification: 1 })
w.upsert_edge(:WORKS_ON, from: p, to: project, properties: { role: "lead" }, attrs: { classification: 1 })
```

A refused write raises `Pglpg::WriteRejected` with no Ref and no row data,
whether the target is hidden, missing or not allowed. Writes run in a
savepoint, so a refusal never aborts your transaction.

## Query

```ruby
rows = g.match
        .node(:p, :Person, uid: "PER-12")
        .out(:WORKS_ON, :j, :Project, edge: :w)
        .in(:WORKS_ON, :q, :Person, from: :j)      # branch from an earlier variable
        .where(j: { headcount: Pglpg.gt(0) }, w: { role: "lead" })
        .return(:q, :j)
        .order(q: :name)
        .limit(50)
        .to_a
rows.first[:q]   # => #<Pglpg::Node ...>

g.find(ref)                         # visible node or edge, else nil
g.find_node(:Person, uid: "PER-12")
query.count; query.exists?; query.first; query.distinct; query.explain(analyze: true)

# Symmetric edge types use both (out and in refuse them). Each edge binds once
# per orientation, so list edges once with return(:f).distinct.
g.match.node(:p, ref: ann).both(:FRIEND, :q, :Person, edge: :f)
```

Conditions are structured only: a value (equality), an array (one of), nil
(absent), or `Pglpg.gt / gte / lt / lte / ne / in`. Queries without a limit
raise `Pglpg::TooManyRows` beyond `max_rows` (default 1000); reads run under
`statement_timeout` (default 5 s) and raise `Pglpg::QueryTimeout`.

## Reachability

```ruby
r = g.reachable(from: ann, via: %i[KNOWS], max_depth: 3, max_nodes: 500, deadline: 2.0)
r.nodes             # => [[ref, 1], [ref, 1], [ref, 2], …]  by depth, then id
r.complete?         # false when more visible nodes are reachable within max_depth
r.stopped_at_depth  # depth of the last returned node when incomplete, else nil

g.reachable(from: ann, via: %i[KNOWS], direction: :in, max_depth: 2, max_nodes: 100)
g.reachable(from: ann, via: %i[FRIEND], direction: :both, max_depth: 2, max_nodes: 100)
```

Each visible node comes once, at its minimum depth; the start node never does.
Hidden nodes and edges are never traversed, and a hidden or missing start gives
an empty, complete result. `via` lists edge types that may be followed at any
hop. `direction:` follows the same rule as `match`: `:both` takes only
symmetric types, `:out` (the default) and `:in` only directed ones.
`max_nodes` may not exceed `max_rows`.

The traversal is one SQL statement (ADR-0009), so it sees one snapshot at any
isolation level. `deadline` is in seconds and can only shorten the configured
`statement_timeout`; with no timeout configured it applies alone. Running out
of time raises `Pglpg::QueryTimeout` and leaves your transaction usable.

## Models and eager loading

`require "pglpg/model"` adds optional ActiveModel records bound to a graph and
schema type. Context-bound relations support reads, guarded saves, associations,
`pluck` and visibility-aware batched eager loading with `with_associations`.
See the [API contract](https://knowen.md/nodes/36329) for examples, cache lifetime
and row limits.

## Scoped keys

A type can declare `key :uid, scope: :namespace` when both properties are
required strings. Uniqueness covers the scope/key pair across the type and its
subtypes. `find_node` and trusted upserts require both values. An interactive
caller-chosen key needs an explicit `key_scope_allowed` grant: it permits
learning occupancy in that scope, including hidden collisions, without granting
row access. Scope and key are immutable. Existing data needs a transactional
backfill and constraint migration; see the
[API contract](https://knowen.md/nodes/36329).

## Composite and edge keys (0.3.0 candidate)

Keys can use a tuple of required string, integer, boolean or enum properties:

```ruby
node :Document do
  property :catalog, :string, required: true
  property :number, :integer, required: true
  key :catalog, :number
end
edge :CITES, from: :Document, to: :Document do
  property :source, :string, required: true
  property :external_id, :string, required: true
  key :source, :external_id
end
```

General tuples and single non-string keys require a trusted writer on insert.
Single string keys retain automatic generation; existing scoped node keys
retain their explicit occupancy grant. Edge keys are unique within the edge
type, independently of endpoints. A keyed edge upsert requires the full key
and the original endpoints; it cannot rewire a relationship.

```ruby
w = ctx.trusted_writer
ref = w.upsert_node(:Document, key: { catalog: "main", number: 7 })
ctx.find_node(:Document, catalog: "main", number: 7)
w.upsert_edge(:CITES, from: ref, to: other,
              key: { source: "archive", external_id: "citation-1" })
ctx.find_edge(:CITES, source: "archive", external_id: "citation-1")
```

`unique: [:role]` on an edge type adds the required role to its endpoint-pair
uniqueness tuple. It allows different roles between the same endpoints and
requires trusted insertion/upsert. A declared `key` and `unique:` can coexist;
keyed upsert uses the key, and both constraints still apply. All key and
uniqueness properties are immutable, and uniqueness spans all validity dates.
Symmetric types use the canonical unordered endpoint pair.

Composite model attributes are required; create with `save(writer: w)` using
the record's own context's writer. Generated model keys remain unassignable.
Existing data needs an explicit transactional backfill/deduplication followed
by `storage.sync_constraints!` on the same connection. No automatic migration
runs when a declaration is loaded. Other property types, optional uniqueness
and multiple alternate keys are outside this key API.

## Open properties (0.3.0 candidate)

Types stay closed by default. Opt in to extra properties explicitly:

```ruby
node :Person, open: true do
  property :uid, :string, required: true
  key :uid
end
edge :MENTIONS, from: :Person, to: :Person, open: true

ref = ctx.insert_node(:Person, properties: { source_note: "archive", scores: [1, 2] })
ctx.find(ref)[:scores] # => [1, 2], frozen
ctx.update_node(ref, properties: { source_note: nil }) # removes the extra
```

An open parent makes its descendants open, including with multiple parents;
`open: false` on a child does not close an open ancestor. Declared properties,
keys, endpoints and generated labels retain their rules.

Extras accept strings, integers, finite floats, booleans and flat homogeneous
scalar arrays (including empty arrays). Nil means absent/removal. Maps, nested
or mixed arrays, nil array members, Symbols, dates/times, decimals and custom
objects need explicit application conversion or a declared property type.
Extra names cannot collide with structural row names, regardless of element
kind (so even a node extra cannot be named `type`, `source_id` or `target_id`).
Validity names `valid_from`/`valid_to` are reserved even in wholly timeless
graphs. Application-column names of that element kind are also reserved.
Invalid names are refused. On open types, duplicate String/Symbol aliases are
rejected for every submitted property, including declared properties. Closed
types retain their existing last-alias normalization.

Queries, ordering, model attributes and `pluck` still require declarations.
Models expose extras through their read-only `extra_properties`; saving declared
attributes preserves them. Write extras through `Context`/`Writer` and reload
the model to refresh its map. No dynamic query casts or model setters are added.

Extras carry application data and gain no automatic tenant/ACL or visibility
semantics. Existing row/write policies still apply, and write policies can
inspect submitted extras. Keep security-relevant fields in explicit declarations
or application columns, with an explicit authorization policy.

Openness alone adds no DDL. Closing a type preserves existing extra data on
reads and declared-only updates; it refuses resubmitted unknown properties.
Audit/backfill before closing types or promoting extras to typed declarations.
Shape validation is at the library write boundary; raw SQL does not gain an
open/closed constraint. The existing required-property and key checks remain.

## Temporal edges (0.3.0 candidate)

Opt in per edge type and use one date across the whole query:

```ruby
edge :MEMBER_OF, from: :Person, to: :Organization, temporal: true

w = Kg.for(viewer: current_viewer)
w.insert_edge(:MEMBER_OF, from: ann, to: org,
              valid_from: Date.new(2020, 1, 1), valid_to: Date.new(2021, 1, 1),
              attrs: { classification: 1 })

at = Kg.for(viewer: current_viewer, as_of: Date.new(2020, 6, 1))
at.match.node(:p, ref: ann).out(:MEMBER_OF, :o).to_a
all_dates = Kg.for(viewer: current_viewer, as_of: :any)
```

Intervals include the start and exclude the end. Bounds are exact Ruby Dates
in 0001–9999 or nil for unbounded; unknown/uncertain dates need separate
application metadata. Required `valid_from:` presence on insert/upsert makes
all-time intent explicit (`valid_from: nil`). Updates preserve omitted bounds;
upserts preserve an omitted `valid_to` on conflict but use nil on insert.

Date contexts are read-only, including model saves. Omitting `as_of` permits
node-only and timeless-only reads; temporal reads raise `TemporalModeRequired`.
Generic edge `find(ref)` requires a mode whenever the schema has a temporal
type. `:any` remains writable and always retains current visibility. Dated
reachability, models and preloads use the same date on every hop. This does not
reconstruct old values, node existence or past permissions.

`unique: :pair` still spans all dates. Leave/rejoin episodes with a gap need
separate Refs on a non-pair-unique type; overlaps are allowed.

Run the temporal migration before routing dated reads or temporal writes to the
updated graph declaration. Loading `temporal: true` does not migrate its tables.
During a deploy-then-migrate window, keep temporal edge operations disabled
until the migration commits. Storage helpers report `TemporalMigrationRequired`;
ordinary reads/writes do not inspect the catalog, so unmigrated operations may
raise `ActiveRecord::StatementInvalid` with `PG::UndefinedColumn` instead.
An explicit `:any` read can still work without date columns and does not prove
that the migration is complete.

For existing tables, remove conflicting application declarations and migrate
incompatible legacy timestamp columns explicitly before enabling temporal types:

```ruby
Kg.storage.enable_temporal!(types: [:MEMBER_OF], backfill: ->(connection) {
  # Explicit application backfill, on this connection, after checks are enabled.
  # Without a callback, existing bounds are preserved; newly added NULL bounds
  # deliberately mean all-time. Never invent dates or silently discard times.
})
```

The helper locks the edge table, adds missing nullable date columns and runs
constraint sync/backfill atomically. An outer transaction keeps its work pending
until commit. Callback errors or invalid intervals roll everything back; the
callback must not commit or switch connections. Callback idempotency is yours.
Bare `sync_constraints!` refuses missing columns or unacknowledged populated
temporal types. Once temporal columns exist, every synchronization takes an
`ACCESS EXCLUSIVE` edge-table lock, including after the last temporal type is
disabled and for unrelated schema changes. This blocks edge reads and writes
until the caller's outer commit; keep the migration transaction short and
schedule it accordingly. Physical columns remain after temporal types are disabled.
See [ADR-0013](https://knowen.md/nodes/36532) for the complete contract.

## Leak specs for your policy

```ruby
require "pglpg/testing"

RSpec.describe ClearancePolicy do
  it_behaves_like "a pglpg visibility policy" do
    let(:pglpg_visibility)    { ClearancePolicy }
    let(:pglpg_viewer)        { Viewer.new(clearance: 2) }
    let(:pglpg_columns)       { { classification: [:integer, { null: false }] } }
    let(:pglpg_visible_attrs) { { classification: 2 } }
    let(:pglpg_hidden_attrs)  { { classification: 3 } }
  end
end
```

## Development

```bash
createdb pglpg_test
bundle install
bundle exec rspec
```

`PGLPG_DATABASE_URL` overrides the test database (use one per worktree).
The benchmark is described in [bench/README.md](bench/README.md).
