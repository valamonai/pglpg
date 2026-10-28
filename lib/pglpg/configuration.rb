# frozen_string_literal: true

module Pglpg
  # Global settings. Each graph can override visibility, write_policy and
  # trusted_writer_allowed when it is defined.
  class Configuration
    # Required. An object with +node(table, viewer)+ and +edge(table, viewer)+,
    # each returning an Arel condition on the given Arel::Table.
    attr_accessor :visibility

    # Required for writes. An object with +authorize?(request)+ and, optionally,
    # +existing(table, request)+ returning an Arel condition on the stored row.
    attr_accessor :write_policy

    # A callable +->(context) { ... }+ returning true when the trusted writer
    # may be used for that context. Unset means the capability is never granted.
    attr_accessor :trusted_writer_allowed

    # The ActiveRecord class whose connection pglpg uses.
    attr_accessor :connection_class

    # Queries without an explicit limit raise TooManyRows above this many rows.
    attr_accessor :max_rows

    # Statement timeout for reads, in milliseconds. nil leaves the session value.
    attr_accessor :statement_timeout

    def initialize
      @connection_class = nil
      @max_rows = 1000
      @statement_timeout = 5000
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
