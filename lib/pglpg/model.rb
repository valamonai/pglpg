# frozen_string_literal: true

require "pglpg"
require "active_model"

module Pglpg
  # The optional model layer (ADR-0010): ActiveModel classes backed by graph
  # node and edge types, read through a Context.
  #
  #   require "pglpg/model"
  #
  #   class Person < Pglpg::Model::Node
  #     graph Kg, type: :Person
  #   end
  #
  #   people = Person.in(Kg.for(viewer: current_viewer))
  #   people.where(rank: Pglpg.gte(2)).order(name: :desc).limit(20).to_a
  #   people.find(ref)
  module Model
    # A lookup found no visible element of the model's type. A hidden
    # element and a missing one look the same.
    class RecordNotFound < Error
      def initialize(msg = "record not found")
        super
      end
    end

    @registries = ObjectSpace::WeakKeyMap.new
    @lock = Mutex.new

    class << self
      # Registers +klass+ as the model of +type_name+ in +graph+. A class
      # with the same name replaces an earlier one (code reloading); any
      # other second model for the same type is a ConfigurationError.
      def register(graph, kind, type_name, klass)
        @lock.synchronize do
          registry = (@registries[graph] ||= {})
          existing = registry[[kind, type_name]]
          if existing && !existing.equal?(klass) && (existing.name.nil? || existing.name != klass.name)
            raise ConfigurationError, "#{type_name} in graph #{graph.name} already has a model (#{existing.inspect})"
          end

          registry[[kind, type_name]] = klass
        end
      end

      # The model registered for +type_name+ in +graph+, or nil.
      def lookup(graph, kind, type_name)
        @lock.synchronize { @registries[graph]&.[]([kind, type_name]) }
      end
    end
  end
end

require_relative "model/base"
require_relative "model/node"
require_relative "model/edge"
require_relative "model/relation"
