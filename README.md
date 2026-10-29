# pglpg

Labeled property graphs stored in plain PostgreSQL tables, for Ruby.

pglpg follows the ISO GQL property graph model and PG-Schema / PG-Keys. It
needs no PostgreSQL extension and no second database: each graph is two
ordinary tables, written inside your own transactions. Every query applies
your visibility policy to every node and edge on every hop, so hidden records
never act as bridges and never show up in counts or limits.

Status: **0.1, pre-release.** The design and its decisions live in the
[pglpg.md](https://knowen.md/nodes/36325) knowledge base. Requires Ruby ≥ 4.0,
ActiveRecord ≥ 8.1 and PostgreSQL ≥ 18: the versions CI tests.

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
(`enum` takes `values:`, `list` takes `of:`). Types are closed: undeclared
properties are rejected. A nil value means the property is absent.

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
