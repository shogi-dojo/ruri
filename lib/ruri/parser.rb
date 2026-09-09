# frozen_string_literal: true

require "prism"

module Ruri
  # Parses .ruri source with Prism and validates it against the v0
  # language contract (docs/language.md). Never evaluates the input.
  #
  #   Ruri::Parser.parse(source, path: "hello.ruri")
  #   # => [<Forms::Command ...>]  or raises Ruri::CompileError
  class Parser
    NAME_RE = /\A[a-z][a-z0-9_]*\z/.freeze

    class << self
      def parse(source, path:)
        new(source, path).parse
      end
    end

    def initialize(source, path)
      @source = source
      @path = path
      @diagnostics = []
      @commands = []
      @seen_names = {}
    end

    def parse
      result = Prism.parse(@source)
      if result.errors.any?
        result.errors.each do |error|
          @diagnostics << diagnostic(error.location, "syntax error: #{error.message}")
        end
        fail!
      end
      @result = result
      result.value.statements.body.each { |node| parse_top_level(node) }
      fail! if @diagnostics.any?
      @commands
    end

    private

    def fail!
      raise CompileError, @diagnostics
    end

    def diagnostic(location, message)
      Diagnostic.new(
        path: @path,
        line: location.start_line,
        column: location.start_column + 1,
        message: message
      )
    end

    def error(location, message)
      @diagnostics << diagnostic(location, message)
      nil
    end

    def unsupported(node)
      message =
        if node.is_a?(Prism::CallNode)
          if node.receiver
            "unsupported construct: method call `#{node.name}` with explicit receiver"
          else
            "unsupported construct: method call `#{node.name}`"
          end
        else
          "unsupported construct: #{node.class.name.delete_prefix("Prism::")}"
        end
      error(node.location, message)
    end

    def raw_slice(node)
      location = node.location
      @source.byteslice(location.start_offset, location.length)
    end

    # True when the raw source of a double-quoted literal contains an
    # unescaped `#{` (see Ruri::SourceScan).
    def interpolated_slice?(node)
      Ruri::SourceScan.interpolated?(raw_slice(node))
    end

    # Returns [true, string_value] or [false, diagnostic].
    def extract_string(node)
      case node
      when Prism::StringNode
        opening = node.opening
        if opening&.start_with?("<<")
          return [false, error(node.location, "heredocs are not supported in v0")]
        end
        unless ["\"", "'"].include?(opening)
          return [false, error(node.location,
                               "unsupported string literal form; only \"...\" and '...' are supported in v0")]
        end
        if opening == "\"" && interpolated_slice?(node)
          return [false, error(node.location, "string interpolation is not supported in v0")]
        end
        [true, node.unescaped]
      when Prism::InterpolatedStringNode
        [false, error(node.location,
                      "interpolated or adjacent string literals are not supported in v0")]
      else
        [false, error(node.location, "literal string argument required")]
      end
    end

    # Returns [true, symbol_name] or [false, diagnostic].
    def extract_symbol(node)
      case node
      when Prism::SymbolNode
        opening = node.opening
        unless [":", ":\""].include?(opening)
          return [false, error(node.location, "unsupported symbol literal form")]
        end
        if opening == ":\"" && interpolated_slice?(node)
          return [false, error(node.location, "symbol interpolation is not supported in v0")]
        end
        [true, node.unescaped]
      when Prism::InterpolatedSymbolNode
        [false, error(node.location, "symbol interpolation is not supported in v0")]
      else
        [false, error(node.location, "command requires exactly one literal symbol argument")]
      end
    end

    def block_parameters_location(block)
      block.parameters&.location
    end

    def parse_top_level(node)
      unless node.is_a?(Prism::CallNode) && node.name == :command
        unsupported(node)
        return
      end
      if node.receiver
        error(node.location, "unsupported construct: method call `command` with explicit receiver")
        return
      end
      if node.block.nil?
        error(node.location, "command requires a do...end block")
        return
      end
      if node.block.parameters
        error(block_parameters_location(node.block), "command blocks do not take parameters")
        return
      end

      args = node.arguments&.arguments || []
      if args.length != 1
        error(node.location, "command requires exactly one literal symbol argument")
        return
      end
      ok, source_name = extract_symbol(args[0])
      return unless ok

      unless source_name.match?(NAME_RE)
        error(args[0].location,
              "invalid command name `#{source_name}`; must match [a-z][a-z0-9_]*")
        return
      end

      lisp_name = source_name.tr("_", "-")
      if @seen_names.key?(lisp_name)
        error(args[0].location, "duplicate command definition `#{lisp_name}`")
        return
      end
      @seen_names[lisp_name] = source_name

      body = parse_command_body(node.block)
      @commands << Forms::Command.new(source_name: source_name, name: lisp_name, body: body)
    end

    def parse_command_body(block)
      statements = block.body&.body || []
      forms = []
      interactive_seen = false
      interactive_problem_reported = false
      statements.each_with_index do |stmt, index|
        unless stmt.is_a?(Prism::CallNode)
          unsupported(stmt)
          next
        end
        case stmt.name
        when :interactive
          if index.zero? && !interactive_seen
            interactive_seen = true
            if stmt.arguments
              interactive_problem_reported = true
              error(stmt.location, "interactive takes no arguments")
            elsif stmt.block
              interactive_problem_reported = true
              error(stmt.location, "interactive does not take a block")
            else
              forms << Forms::Interactive.new
            end
          else
            interactive_problem_reported = true
            error(stmt.location, "interactive must appear exactly once, as the first statement of the command body")
          end
        when :command
          error(stmt.location, "nested command definitions are not supported")
        when :with_current_buffer
          if (form = parse_with_current_buffer(stmt))
            forms << form
          end
        when :insert
          if (form = parse_insert(stmt))
            forms << form
          end
        else
          unsupported(stmt)
        end
      end
      unless interactive_seen || interactive_problem_reported
        anchor = statements.first&.location || block.location
        error(anchor, "command body must start with interactive")
      end
      forms
    end

    def parse_with_current_buffer(node)
      if node.receiver
        error(node.location, "unsupported construct: method call `with_current_buffer` with explicit receiver")
        return nil
      end
      if node.block.nil?
        error(node.location, "with_current_buffer requires a do...end block")
        return nil
      end
      if node.block.parameters
        error(block_parameters_location(node.block), "with_current_buffer blocks do not take parameters")
        return nil
      end

      args = node.arguments&.arguments || []
      if args.length != 1
        error(node.location, "with_current_buffer requires exactly one literal string argument")
        return nil
      end
      ok, buffer = extract_string(args[0])
      return nil unless ok

      inner_statements = node.block.body&.body || []
      if inner_statements.empty?
        error(node.block.location, "with_current_buffer requires a nonempty do...end block")
        return nil
      end

      body = parse_buffer_statements(inner_statements)
      Forms::WithCurrentBuffer.new(buffer: buffer, body: body)
    end

    def parse_insert(node)
      if node.receiver
        error(node.location, "unsupported construct: method call `insert` with explicit receiver")
        return nil
      end
      if node.block
        error(node.location, "insert does not take a block")
        return nil
      end

      args = node.arguments&.arguments || []
      if args.length != 1
        error(node.location, "insert requires exactly one literal string argument")
        return nil
      end
      ok, text = extract_string(args[0])
      return nil unless ok

      Forms::Insert.new(text: text)
    end

    # Statements inside a with_current_buffer block: only nested buffer
    # blocks and insert are valid here; interactive belongs to the command
    # body alone.
    def parse_buffer_statements(statements)
      forms = []
      statements.each do |stmt|
        unless stmt.is_a?(Prism::CallNode)
          unsupported(stmt)
          next
        end
        case stmt.name
        when :interactive
          error(stmt.location, "interactive is only allowed as the first statement of a command body")
        when :command
          error(stmt.location, "nested command definitions are not supported")
        when :with_current_buffer
          if (form = parse_with_current_buffer(stmt))
            forms << form
          end
        when :insert
          if (form = parse_insert(stmt))
            forms << form
          end
        else
          unsupported(stmt)
        end
      end
      forms
    end
  end
end
