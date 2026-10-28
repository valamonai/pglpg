# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Run the benchmark (see bench/README.md)"
task :bench do
  ruby "bench/run.rb"
end

task default: :spec
