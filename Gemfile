# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# CI runs the suite against several ActiveRecord versions.
gem "activerecord", "~> #{ENV["AR_VERSION"]}.0" if ENV["AR_VERSION"]

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
