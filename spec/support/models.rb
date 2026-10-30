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
  end

  class Project < Pglpg::Model::Node
    graph Kg, type: :Project
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
