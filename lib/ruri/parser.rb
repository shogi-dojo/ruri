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
    ELISP_CALL_NAME_RE = /\A[a-z][a-z0-9_]*[!?]?\z/.freeze

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

    def el_namespace?(node)
      node.is_a?(Prism::CallNode) &&
        node.name == :el &&
        node.receiver.nil? &&
        node.arguments.nil? &&
        node.block.nil? &&
        node.opening_loc.nil?
    end

    def elisp_call?(node)
      node.is_a?(Prism::CallNode) &&
        node.call_operator == "." &&
        el_namespace?(node.receiver)
    end

    def normalize_elisp_name(name)
      name.to_s.tr("_", "-")
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

      body = with_local_scope(node.block) { parse_command_body(node.block) }
      @commands << Forms::Command.new(source_name: source_name, name: lisp_name, body: body)
    end

    def with_local_scope(block)
      previous_names = @local_names
      @local_names = collect_local_names(block)
      yield
    ensure
      @local_names = previous_names
    end

    def collect_local_names(node, names = {})
      return names.keys unless node

      if node.is_a?(Prism::LocalVariableWriteNode)
        names[node.name.to_s] = true
      end
      node.child_nodes.each { |child| collect_local_names(child, names) }
      names.keys
    end

    def generated_local_name(source_name)
      "ruri--local-#{source_name.tr("_", "-")}"
    end

    def parse_command_body(block)
      statements = block.body&.body || []
      forms = []
      interactive_seen = false
      interactive_problem_reported = false
      statements.each_with_index do |stmt, index|
        if stmt.is_a?(Prism::LocalVariableWriteNode) ||
           stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode)
          form = parse_structured_statement(stmt)
          forms << form if form
          next
        end
        unless stmt.is_a?(Prism::CallNode)
          unsupported(stmt)
          next
        end
        if elisp_call?(stmt)
          form = parse_elisp_call(stmt)
          forms << form if form
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

    def parse_structured_statement(node)
      case node
      when Prism::LocalVariableWriteNode
        parse_local_write(node)
      when Prism::IfNode
        parse_conditional(node, negated: false)
      when Prism::UnlessNode
        parse_conditional(node, negated: true)
      else
        unsupported(node)
      end
    end

    def parse_local_write(node)
      source_name = node.name.to_s
      unless source_name.match?(NAME_RE) && source_name != "t"
        error(node.name_loc || node.location,
              "invalid local variable name `#{source_name}`")
        return nil
      end

      value = parse_expression(node.value)
      return nil unless value

      Forms::LocalWrite.new(
        source_name: source_name,
        name: generated_local_name(source_name),
        value: value
      )
    end

    def parse_conditional(node, negated:)
      condition = parse_expression(node.predicate)
      then_body = parse_buffer_statements(node.statements&.body || [])
      else_body = parse_conditional_else(node)
      return nil unless condition

      Forms::Conditional.new(
        condition: condition,
        then_body: then_body,
        else_body: else_body,
        negated: negated
      )
    end

    def parse_conditional_else(node)
      clause = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
      case clause
      when nil
        []
      when Prism::ElseNode
        parse_buffer_statements(clause.statements&.body || [])
      when Prism::IfNode
        form = parse_conditional(clause, negated: false)
        form ? [form] : []
      else
        unsupported(clause)
        []
      end
    end

    def parse_elisp_call(node)
      if node.block
        error(node.location, "el.* calls do not take blocks")
        return nil
      end

      source_name = node.name.to_s
      unless source_name.match?(ELISP_CALL_NAME_RE)
        error(node.message_loc || node.location,
              "invalid el.* function name `#{source_name}`; use lowercase snake_case")
        return nil
      end

      arguments = node.arguments&.arguments || []
      parsed_arguments = arguments.map { |argument| parse_expression(argument) }
      return nil if parsed_arguments.any?(&:nil?)

      Forms::Call.new(
        name: normalize_elisp_name(source_name),
        arguments: parsed_arguments
      )
    end

    def parse_expression(node)
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode
        ok, value = extract_string(node)
        ok ? Forms::Literal.new(kind: :string, value: value) : nil
      when Prism::IntegerNode
        Forms::Literal.new(kind: :integer, value: node.value)
      when Prism::FloatNode
        Forms::Literal.new(kind: :float, value: node.value)
      when Prism::TrueNode
        Forms::Literal.new(kind: :true, value: true)
      when Prism::FalseNode
        Forms::Literal.new(kind: :false, value: false)
      when Prism::NilNode
        Forms::Literal.new(kind: :nil, value: nil)
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode
        parse_symbol_expression(node)
      when Prism::ArrayNode
        elements = node.elements.map { |element| parse_expression(element) }
        elements.any?(&:nil?) ? nil : Forms::Vector.new(elements: elements)
      when Prism::LocalVariableReadNode
        parse_local_read(node)
      when Prism::CallNode
        return parse_elisp_call(node) if elisp_call?(node)
        # Ruby parses a bare name used before its first textual assignment as
        # a zero-argument call. Ruri locals have command-wide lexical scope,
        # so reinterpret that precise shape when a matching assignment exists.
        return parse_local_read(node) if local_reference_call?(node)

        error(node.location,
              "unsupported expression: only locals, el.* calls, and literals are allowed")
      else
        error(node.location,
              "unsupported expression: #{node.class.name.delete_prefix("Prism::")}")
      end
    end

    def parse_local_read(node)
      source_name = node.name.to_s
      unless @local_names&.include?(source_name)
        error(node.location, "local variable `#{source_name}` is not defined in this command")
        return nil
      end

      Forms::LocalRead.new(
        source_name: source_name,
        name: generated_local_name(source_name)
      )
    end

    def local_reference_call?(node)
      @local_names&.include?(node.name.to_s) &&
        node.receiver.nil? && node.arguments.nil? && node.block.nil? &&
        node.opening_loc.nil?
    end

    def parse_symbol_expression(node)
      ok, value = extract_symbol(node)
      return nil unless ok

      normalized = normalize_elisp_name(value)
      unless normalized.match?(Elisp::SYMBOL_RE)
        error(node.location, "invalid Emacs Lisp symbol literal `#{value}`")
        return nil
      end

      Forms::Literal.new(kind: :symbol, value: normalized)
    end

    # Statements inside a with_current_buffer block: only nested buffer
    # blocks and insert are valid here; interactive belongs to the command
    # body alone.
    def parse_buffer_statements(statements)
      forms = []
      statements.each do |stmt|
        if stmt.is_a?(Prism::LocalVariableWriteNode) ||
           stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode)
          form = parse_structured_statement(stmt)
          forms << form if form
          next
        end
        unless stmt.is_a?(Prism::CallNode)
          unsupported(stmt)
          next
        end
        if elisp_call?(stmt)
          form = parse_elisp_call(stmt)
          forms << form if form
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
