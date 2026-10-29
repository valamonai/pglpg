# frozen_string_literal: true

require "active_record"
require "json"

require_relative "pglpg/version"
require_relative "pglpg/errors"
require_relative "pglpg/configuration"
require_relative "pglpg/schema/property"
require_relative "pglpg/schema/element_type"
require_relative "pglpg/schema/node_type"
require_relative "pglpg/schema/edge_type"
require_relative "pglpg/schema/column"
require_relative "pglpg/schema/graph_type"
require_relative "pglpg/ref"
require_relative "pglpg/element"
require_relative "pglpg/condition"
require_relative "pglpg/sql"
require_relative "pglpg/storage"
require_relative "pglpg/graph"
require_relative "pglpg/context"
require_relative "pglpg/writer"
require_relative "pglpg/query"
require_relative "pglpg/reachability"

# Labeled property graphs stored in plain PostgreSQL tables.
module Pglpg
end
