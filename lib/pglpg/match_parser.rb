# frozen_string_literal: true

require "strscan"

module Pglpg
  # The text front end builds the same immutable query state as the Ruby DSL.
  class MatchParser
    MAX_BYTES = 8 * 1024
    MAX_HOPS = 8
    MAX_PREDICATES = 32
    MAX_PARAMETERS = 32

    IDENTIFIER = /[A-Za-z_][A-Za-z_0-9]*/
    PARAMETER = /\$#{IDENTIFIER}/
    TOKEN = /#{PARAMETER}|#{IDENTIFIER}|[0-9]+|->|<-|[^\s]/
    KEYWORDS = %w[MATCH WHERE AND RETURN DISTINCT ORDER BY ASC DESC LIMIT].freeze
    UNSUPPORTED_WORDS = %w[OPTIONAL CREATE INSERT DELETE DETACH SET REMOVE MERGE
                           CALL WITH UNION OFFSET SKIP GROUP HAVING].freeze
    CONDITION_PREFIXES = %w[NOT ANY ALL NONE SINGLE EXISTS].freeze
    CONDITION_OPERATORS = %w[IS IN NOT STARTS ENDS CONTAINS LIKE BETWEEN].freeze
    CONDITION_CONNECTORS = %w[OR XOR].freeze
    Token = Data.define(:text, :position)

    def initialize(context, text, params)
      raise ArgumentError, "MATCH text must be a String" unless text.is_a?(String)

      @context = context
      @text = text
      @params = params
      @bindings = {}
      @types = {}
    end

    def parse
      validate_text!
      @scanner = StringScanner.new(@text)
      advance
      expect("MATCH")
      start = node_pattern
      hops = []
      hops << edge_pattern while %w[- <- ~].include?(@token.text)
      fail_at(:unsupported, "multiple patterns are outside the MATCH subset") if @token.text == ","
      predicates = read_predicates
      expect("RETURN")
      distinct = accept("DISTINCT")
      returns = [return_binding]
      returns << return_binding while accept(",")
      order = read_order if accept("ORDER")
      limit = take_integer if accept("LIMIT")
      accept(";")
      expect_end!

      if distinct && order && returns.none? { |var| var.text == order.first.text }
        fail_at(:syntax, "DISTINCT ordering requires a returned binding", order.first)
      end
      check_cap(hops.size, MAX_HOPS, "hops", hops[MAX_HOPS]&.first)
      check_cap(predicates.size, MAX_PREDICATES, "WHERE predicates", predicates[MAX_PREDICATES]&.first)
      row_limit = validate_limit(limit)
      values = parameter_values(predicates.map(&:last))

      query = build_pattern(start, hops)
      predicates.each do |var, name, param|
        property!(var, name)
        begin
          query = query.where(var.text.to_sym => { name.text.to_sym => values.fetch(param.text.delete_prefix("$")) })
        rescue ValidationError, ArgumentError, RangeError
          fail_at(:parameter, "invalid equality value", param)
        end
      end
      returns.each { type_for!(_1) }
      query = query.return(*returns.map { _1.text.to_sym })
      query = query.distinct if distinct
      if order
        var, name, direction = order
        property!(var, name)
        query = query.order(var.text.to_sym => { name.text.to_sym => direction })
      end
      row_limit ? query.limit(row_limit) : query
    end

    private

    def validate_text!
      unless [Encoding::UTF_8, Encoding::US_ASCII].include?(@text.encoding)
        fail_at(:syntax, "text must use UTF-8 or US-ASCII", Token.new(nil, 0))
      end
      if @text.bytesize > MAX_BYTES
        fail_at(:limit_exceeded, "text exceeds #{MAX_BYTES} bytes", Token.new(nil, MAX_BYTES))
      end
      return if @text.valid_encoding?

      offset = 0
      @text.each_char do |char|
        fail_at(:syntax, "invalid text encoding", Token.new(nil, offset)) unless char.valid_encoding?
        offset += char.bytesize
      end
    end

    def advance
      @scanner.skip(/\s+/)
      position = @scanner.pos
      if (comment = @scanner.scan(%r{//|/\*}))
        fail_at(:unsupported, "comments are outside the MATCH subset", Token.new(comment, position))
      end
      @token = Token.new(@scanner.scan(TOKEN), position)
    end

    def take
      token = @token
      advance
      token
    end

    def accept(text)
      take if @token.text&.casecmp?(text)
    end

    def expect(text)
      accept(text) || unexpected("expected #{text}")
    end

    def expect_end!
      unexpected("expected end of input") if @token.text
    end

    def unexpected(message)
      text = @token.text
      unsupported = text && (UNSUPPORTED_WORDS.include?(text.upcase) || %w[{ } | & ! * + %].include?(text))
      fail_at(unsupported ? :unsupported : :syntax, message)
    end

    def identifier
      return take if @token.text&.match?(/\A#{IDENTIFIER}\z/)

      unexpected("expected an identifier")
    end

    def binding
      token = identifier
      name = token.text
      if name.start_with?("_") || KEYWORDS.include?(name.upcase) || @bindings.key?(name)
        fail_at(:syntax, "reserved or duplicate binding", token)
      end
      @bindings[name] = true
      token
    end

    def node_pattern
      expect("(")
      var = binding
      expect(":")
      label = identifier
      expect(")")
      [var, label]
    end

    def edge_pattern
      connector = take
      direction, ending = case connector.text
                          when "-" then [:out, "->"]
                          when "<-" then [:in, "-"]
                          when "~" then [:both, "~"]
                          end
      expect("[")
      var = binding unless @token.text == ":"
      expect(":")
      type = identifier
      expect("]")
      if direction == :out && @token.text == "-"
        fail_at(:unsupported, "use a directed arrow or a symmetric tilde")
      end
      expect(ending)
      [connector, direction, var, type, node_pattern]
    end

    def read_predicates
      return [] unless accept("WHERE")

      predicates = []
      loop do
        # Contextual keywords can still name a binding in a property reference.
        prefix = CONDITION_PREFIXES.include?(@token.text&.upcase) && !@scanner.check(/\s*\./)
        if @token.text == "(" || prefix
          fail_at(:unsupported_condition, "only AND-joined equality predicates are supported")
        end
        var, property = property_reference
        unless accept("=")
          fail_at(:unsupported_condition, "only equality predicates are supported") if %w[< > !].include?(@token.text) ||
            CONDITION_OPERATORS.include?(@token.text&.upcase)
          unexpected("expected =")
        end
        unless @token.text&.match?(/\A#{PARAMETER}\z/)
          fail_at(:unsupported_condition, "equality requires a named parameter") if @token.text && @token.text != "$" && !KEYWORDS.include?(@token.text.upcase)
          unexpected("expected a named parameter")
        end
        predicates << [var, property, take]
        fail_at(:unsupported_condition, "only AND conjunctions are supported") if CONDITION_CONNECTORS.include?(@token.text&.upcase)
        break unless accept("AND")
      end
      predicates
    end

    def property_reference
      var = identifier
      expect(".")
      [var, identifier]
    end

    def return_binding
      var = identifier
      fail_at(:unsupported, "RETURN accepts element bindings only") if %w[. ( AS].include?(@token.text&.upcase)
      var
    end

    def read_order
      expect("BY")
      var, name = property_reference
      direction = accept("DESC") ? :desc : :asc
      accept("ASC") if direction == :asc
      fail_at(:unsupported, "ORDER BY accepts one term") if @token.text == ","
      [var, name, direction]
    end

    def take_integer
      return take if @token.text&.match?(/\A[0-9]+\z/)

      unexpected("expected a decimal integer")
    end

    def validate_limit(token)
      return unless token

      limit = token.text.to_i
      fail_at(:syntax, "LIMIT must be positive", token) if limit.zero?
      check_cap(limit, Pglpg.configuration.max_rows, "LIMIT", token)
      limit
    end

    def parameter_values(references)
      origin = Token.new(nil, 0)
      fail_at(:parameter, "params must be a Hash", origin) unless @params.is_a?(Hash)
      named = references.to_h { |token| [token.text.delete_prefix("$"), token] }
      # The predicate cap also bounds the number of distinct references.
      check_cap(@params.size, MAX_PARAMETERS, "parameter entries", origin)

      values = {}
      @params.each do |key, value|
        unless (key.is_a?(String) || key.is_a?(Symbol)) &&
               key.to_s.ascii_only? && key.to_s.match?(/\A#{IDENTIFIER}\z/)
          fail_at(:parameter, "invalid parameter key", origin)
        end
        name = key.to_s
        token = named[name] || origin
        fail_at(:parameter, "duplicate parameter key", token) if values.key?(name)
        fail_at(:parameter, "unused parameter", token) unless named.key?(name)
        if value.nil? || value.is_a?(Array) || value.is_a?(Condition)
          fail_at(:parameter, "equality requires a scalar value", token)
        end
        values[name] = value.is_a?(String) ? value.dup.freeze : value
      end
      named.each { |name, token| fail_at(:parameter, "missing parameter", token) unless values.key?(name) }
      values
    end

    def build_pattern(start, hops)
      schema = @context.graph.type
      var, label = start
      bind_type(var, label, schema.node_types)
      query = @context.match.node(var.text, label.text)
      hops.each do |connector, direction, edge, type, target|
        edge_type = bind_type(edge, type, schema.edge_types)
        if edge_type.symmetric? != (direction == :both)
          fail_at(:unsupported, "edge direction does not match its type", connector)
        end
        var, label = target
        bind_type(var, label, schema.node_types)
        query = query.public_send(direction, type.text, var.text, label.text, edge: edge&.text)
      end
      query
    end

    def bind_type(var, name, types)
      type = types[name.text.to_sym] || fail_at(:unknown_name, "unknown label or edge type", name)
      @types[var.text] = type if var
      type
    end

    def type_for!(var)
      @types[var.text] || fail_at(:unknown_name, "unknown binding", var)
    end

    def property!(var, name)
      property = type_for!(var).property_named(name.text)
      fail_at(:unknown_name, "unknown declared property", name) unless property
      fail_at(:unsupported, "property is not comparable", name) unless property.comparable?
    end

    def check_cap(count, max, unit, token)
      fail_at(:limit_exceeded, "maximum #{unit} is #{max}", token) if count > max
    end

    def fail_at(code, message, token = @token)
      raise ParseError.new(message, code:, text: @text, position: token.position,
                           token: token.text || ("EOF" if token.position == @text.bytesize)), cause: nil
    end
  end
  private_constant :MatchParser
end
