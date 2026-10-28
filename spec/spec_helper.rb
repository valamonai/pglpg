# frozen_string_literal: true

require "delegate"
require "pglpg"
require "pglpg/testing"

DATABASE_URL = ENV.fetch("PGLPG_DATABASE_URL", "postgres:///pglpg_test")

ActiveRecord::Base.establish_connection("#{DATABASE_URL}#{DATABASE_URL.include?("?") ? "&" : "?"}pool=20")
ActiveRecord::Migration.verbose = false

Dir[File.join(__dir__, "support/**/*.rb")].each { require _1 }

RSpec.configure do |config|
  config.expect_with(:rspec) { _1.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = "spec/examples.txt"

  config.before(:suite) do
    TestGraph.setup!
  end

  config.after(:suite) do
    TestGraph.teardown!
  end

  # Each example runs in a transaction that is rolled back, unless it is
  # tagged :committed (concurrency specs), which truncates afterwards.
  config.around do |example|
    Pglpg.reset_configuration!
    TestGraph.configure!
    if example.metadata[:committed]
      begin
        example.run
      ensure
        TestGraph.truncate!
      end
    else
      ActiveRecord::Base.transaction do
        example.run
        raise ActiveRecord::Rollback
      end
    end
  end
end
