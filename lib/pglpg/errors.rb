# frozen_string_literal: true

module Pglpg
  # Base class for every error pglpg raises.
  class Error < StandardError; end

  # Text MATCH errors report byte positions in the submitted query.
  class ParseError < Error
    attr_reader :code, :position, :line, :column, :token

    def initialize(message, code:, text:, position:, token:)
      @code = code
      @position = position
      prefix = text.byteslice(0, position).b
      @line = prefix.count("\n") + 1
      @column = position - (prefix.rindex("\n") || -1)
      @token = token&.freeze
      super("#{message} at line #{line}, column #{column}")
    end
  end

  # The graph type declaration is invalid.
  class SchemaError < Error; end

  # pglpg is used without a required policy or setting.
  class ConfigurationError < Error; end

  class ReadOnlyContext < Error; end
  class TemporalModeRequired < Error; end
  class TemporalMigrationRequired < Error; end

  # A Ref belongs to another graph or is the wrong kind of element.
  class InvalidRef < Error; end

  # Properties or application columns do not match the graph type.
  class ValidationError < Error; end

  # A write was refused: by the write policy, by visibility, or because the
  # target does not exist. The error deliberately carries no Ref and no row
  # data, so a refusal looks the same whatever the reason.
  class WriteRejected < Error
    def initialize(msg = "write rejected")
      super
    end
  end

  # The application did not grant the trusted-writer capability.
  class NotTrusted < Error; end

  # A query without an explicit limit matched more rows than max_rows allows.
  class TooManyRows < Error; end

  # A query ran past its statement timeout.
  class QueryTimeout < Error
    def initialize(msg = "query timed out")
      super
    end
  end
end
