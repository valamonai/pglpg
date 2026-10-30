# frozen_string_literal: true

require "pglpg/model"
require_relative "test_graph"

module ModelSpec
  class Agent < Pglpg::Model::Node
    graph Kg, type: :Agent
  end

  # Employee has no model of its own: its nodes load as Person.
  class Person < Pglpg::Model::Node
    graph Kg, type: :Person
    has_many :projects, :out, edge: :WORKS_ON
    has_many :reviewed_projects, :out, edge: :REVIEWED, model: "ModelSpec::Project"
    has_many :known, :out, edge: :KNOWS
    has_many :known_by, :in, edge: :KNOWS
    has_many :friends, :both, edge: :FRIEND
  end

  class Project < Pglpg::Model::Node
    graph Kg, type: :Project
    has_many :people, :in, edge: :WORKS_ON
  end

  class WorksOn < Pglpg::Model::Edge
    graph Kg, type: :WORKS_ON
  end

  class Friend < Pglpg::Model::Edge
    graph Kg, type: :FRIEND
  end

  class Knows < Pglpg::Model::Edge
    graph Kg, type: :KNOWS
  end

  class Reviewed < Pglpg::Model::Edge
    graph Kg, type: :REVIEWED
  end
end
