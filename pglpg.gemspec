# frozen_string_literal: true

require_relative "lib/pglpg/version"

Gem::Specification.new do |spec|
  spec.name = "pglpg"
  spec.version = Pglpg::VERSION
  spec.authors = ["Anton Fefilov"]
  spec.summary = "Labeled property graphs stored in plain PostgreSQL tables"
  spec.description = "A Ruby library for labeled property graphs (ISO GQL model, PG-Schema / PG-Keys) " \
                     "stored in plain PostgreSQL tables, with a visibility policy applied to every node " \
                     "and edge on every hop."
  spec.homepage = "https://github.com/valamonai/pglpg"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.2"
  spec.add_dependency "pg", ">= 1.5"
end
