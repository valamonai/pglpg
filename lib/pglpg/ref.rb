# frozen_string_literal: true

module Pglpg
  # An immutable, graph-scoped reference to a node or an edge, backed by the
  # element's bigint id. Business keys are for lookup and upsert only; a Ref
  # is how elements refer to each other.
  Ref = Data.define(:graph, :kind, :id) do
    def initialize(graph:, kind:, id:)
      kind = kind.to_sym
      raise ArgumentError, "kind must be :node or :edge" unless %i[node edge].include?(kind)
      raise ArgumentError, "id must be a positive Integer" unless id.is_a?(Integer) && id.positive?

      super(graph: graph.to_sym, kind:, id:)
    end

    def node? = kind == :node

    def edge? = kind == :edge

    # "graph:kind:id", accepted by Graph#parse_ref.
    def to_s = "#{graph}:#{kind}:#{id}"

    def inspect = "#<Pglpg::Ref #{self}>"
  end
end
