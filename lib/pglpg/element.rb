# frozen_string_literal: true

module Pglpg
  # A node read from the graph. Values are frozen.
  class Node
    attr_reader :ref, :key_label, :labels, :properties, :attrs, :created_at, :updated_at

    def initialize(ref:, key_label:, labels:, properties:, attrs:, created_at:, updated_at:)
      @ref = ref
      @key_label = key_label
      @labels = labels
      @properties = properties
      @attrs = attrs
      @created_at = created_at
      @updated_at = updated_at
      freeze
    end

    def id = ref.id

    def [](name) = properties[name.to_sym]

    def label?(label) = labels.include?(label.to_sym)

    def ==(other) = other.is_a?(Node) && other.ref == ref

    alias eql? ==

    def hash = ref.hash

    def inspect = "#<Pglpg::Node #{ref} #{key_label} #{properties.inspect}>"
  end

  # An edge read from the graph. Values are frozen.
  class Edge
    attr_reader :ref, :type, :source, :target, :properties, :attrs, :created_at, :updated_at

    def initialize(ref:, type:, source:, target:, properties:, attrs:, created_at:, updated_at:)
      @ref = ref
      @type = type
      @source = source
      @target = target
      @properties = properties
      @attrs = attrs
      @created_at = created_at
      @updated_at = updated_at
      freeze
    end

    def id = ref.id

    def [](name) = properties[name.to_sym]

    def ==(other) = other.is_a?(Edge) && other.ref == ref

    alias eql? ==

    def hash = ref.hash

    def inspect = "#<Pglpg::Edge #{ref} #{type} #{source.id}->#{target.id} #{properties.inspect}>"
  end
end
