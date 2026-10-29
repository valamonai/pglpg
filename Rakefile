# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Measure and gate the benchmark on FIXTURE (default ci; see bench/README.md)"
task :bench do
  fixture = ENV.fetch("FIXTURE", "ci")
  out = "tmp/bench/#{fixture}"
  ruby "bench/measure.rb", "--fixture", fixture, "--out", out
  ruby "bench/gate.rb", "--candidate", out
end

task default: :spec
