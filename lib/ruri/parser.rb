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
    BINARY_OPERATORS = {
      :+ => "+", :- => "-", :* => "*", :/ => "/", :% => "mod",
      :** => "expt", :< => "<", :<= => "<=", :> => ">", :>= => ">=",
      :== => "equal", :!= => "equal"
    }.freeze
    UNARY_OPERATORS = { :! => "not", :-@ => "-", :+@ => "identity" }.freeze

    class << self
      def parse(source, path:)
        new(source, path).parse
      end
    end

    def initialize(source, path)
      @source = source
      @path = path
      @diagnostics = []
      @definitions = []
      @seen_names = {}
      @seen_variable_names = {}
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
      @definitions
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

    def unqualified_call?(node, name)
      node.is_a?(Prism::CallNode) && node.name == name && node.receiver.nil?
    end

    def normalize_elisp_name(name)
      name.to_s.tr("_", "-")
    end

    def parse_top_level(node)
      unless node.is_a?(Prism::CallNode)
        unsupported(node)
        return
      end
      case node.name
      when :command then parse_command_definition(node)
      when :function then parse_function_definition(node)
      when :variable then parse_variable_definition(node, "variable", "defvar", false)
      when :constant then parse_variable_definition(node, "constant", "defconst", true)
      when :custom then parse_custom_definition(node)
      else unsupported(node)
      end
    end

    def parse_command_definition(node)
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
      unless literal_symbol_node?(args[0])
        error(node.location, "command requires exactly one literal symbol argument")
        return
      end
      definition_name = parse_definition_name(args[0], :command)
      return unless definition_name
      source_name, lisp_name = definition_name

      body = with_local_scope(node.block) { parse_command_body(node.block) }
      @definitions << Forms::Command.new(source_name: source_name, name: lisp_name, body: body)
    end

    def parse_function_definition(node)
      if node.receiver
        error(node.location, "unsupported construct: method call `function` with explicit receiver")
        return
      end
      unless node.block
        error(node.location, "function definition requires a do...end block")
        return
      end

      args = node.arguments&.arguments || []
      if args.length != 1
        error(node.location, "function definition requires exactly one literal symbol argument")
        return
      end
      unless literal_symbol_node?(args[0])
        error(node.location, "function definition requires exactly one literal symbol argument")
        return
      end
      definition_name = parse_definition_name(args[0], :function)
      return unless definition_name
      source_name, lisp_name = definition_name

      parameters = parse_required_block_parameters(node.block, "function")
      return unless parameters
      generated_parameters = parameters.map { |name| generated_local_name(name) }
      statements = node.block.body&.body || []
      docstring = nil
      if unqualified_call?(statements.first, :doc)
        docstring = parse_doc_statement(statements.first)
        statements = statements[1..]
      end
      body = with_local_scope(node.block, parameters) do
        parse_value_body(statements)
      end
      body = [docstring] + body if docstring
      @definitions << Forms::FunctionDefinition.new(
        source_name: source_name,
        name: lisp_name,
        parameters: generated_parameters,
        body: body
      )
    end

    def parse_definition_name(node, kind)
      ok, source_name = extract_symbol(node)
      return nil unless ok

      unless source_name.match?(NAME_RE)
        error(node.location,
              "invalid #{kind} name `#{source_name}`; must match [a-z][a-z0-9_]*")
        return nil
      end

      lisp_name = source_name.tr("_", "-")
      if @seen_names.key?(lisp_name)
        previous_kind = @seen_names.fetch(lisp_name)
        error(node.location,
              "duplicate #{kind} definition `#{lisp_name}`; already defined as #{previous_kind}")
        return nil
      end
      @seen_names[lisp_name] = kind
      [source_name, lisp_name]
    end

    # `variable :name [value] ["doc"]` and `constant :name value ["doc"]`
    # lower to defvar/defconst. Variables and functions live in separate
    # Elisp namespaces, so names are checked against their own map.
    def parse_variable_definition(node, kind, lisp_form, value_required)
      if node.receiver
        error(node.location, "unsupported construct: method call `#{kind}` with explicit receiver")
        return
      end
      if node.block
        error(node.location, "#{kind} does not take a block")
        return
      end

      positional, keywords = split_arguments(node)
      unless keywords.empty?
        error(node.location, "#{kind} does not accept keyword arguments")
        return
      end
      min_args = value_required ? 2 : 1
      unless positional.length.between?(min_args, 3)
        range = value_required ? "two or three" : "one to three"
        error(node.location, "#{kind} requires #{range} arguments: :name#{value_required ? '' : ' [, value]'}, and an optional docstring")
        return
      end

      ok, source_name = extract_symbol(positional[0])
      return unless ok
      unless source_name.match?(NAME_RE) && source_name != "t"
        error(positional[0].location,
              "invalid #{kind} name `#{source_name}`; must match [a-z][a-z0-9_]*")
        return
      end
      lisp_name = source_name.tr("_", "-")
      if @seen_variable_names.key?(lisp_name)
        previous_kind = @seen_variable_names.fetch(lisp_name)
        error(positional[0].location,
              "duplicate #{kind} definition `#{lisp_name}`; already defined as #{previous_kind}")
        return
      end
      @seen_variable_names[lisp_name] = kind

      value = nil
      if positional[1]
        value = parse_expression(positional[1])
        return unless value
      end

      docstring = nil
      if positional[2]
        ok, text = extract_string(positional[2])
        return unless ok

        docstring = text
      end

      form_class = value_required ? Forms::ConstantDefinition : Forms::VariableDefinition
      @definitions << form_class.new(
        source_name: source_name,
        name: lisp_name,
        value: value,
        docstring: docstring
      )
    end

    # `custom :name value ["doc"] [type: expression]` lowers to defcustom.
    # The type value lowers like any expression, so `type: :string` emits
    # :type 'string and richer types use quote/quasiquote data.
    def parse_custom_definition(node)
      if node.receiver
        error(node.location, "unsupported construct: method call `custom` with explicit receiver")
        return
      end
      if node.block
        error(node.location, "custom does not take a block")
        return
      end

      positional, keywords = split_arguments(node)
      unknown = keywords.map(&:first).reject { |name| name == "type" }
      unless unknown.empty?
        error(node.location, "custom does not accept keyword arguments: #{unknown.join(', ')}; only type: is allowed")
        return
      end
      unless positional.length.between?(2, 3)
        error(node.location, "custom requires two or three arguments: :name, value, and an optional docstring")
        return
      end

      ok, source_name = extract_symbol(positional[0])
      return unless ok
      unless source_name.match?(NAME_RE) && source_name != "t"
        error(positional[0].location,
              "invalid custom name `#{source_name}`; must match [a-z][a-z0-9_]*")
        return
      end
      lisp_name = source_name.tr("_", "-")
      if @seen_variable_names.key?(lisp_name)
        previous_kind = @seen_variable_names.fetch(lisp_name)
        error(positional[0].location,
              "duplicate custom definition `#{lisp_name}`; already defined as #{previous_kind}")
        return
      end
      @seen_variable_names[lisp_name] = "custom"

      value = parse_expression(positional[1])
      return unless value

      docstring = nil
      if positional[2]
        ok, text = extract_string(positional[2])
        return unless ok

        docstring = text
      end

      type = nil
      if (type_node = keywords.assoc("type")&.last)
        type = parse_expression(type_node)
        return unless type
      end

      @definitions << Forms::CustomDefinition.new(
        source_name: source_name,
        name: lisp_name,
        value: value,
        docstring: docstring,
        type: type
      )
    end

    # Splits a call's arguments into positional nodes and keyword
    # (name, value) pairs from a trailing `name: value` hash. DSL
    # definition forms use the keyword pairs sparingly and explicitly.
    def split_arguments(node)
      args = node.arguments&.arguments || []
      keywords = []
      positional = []
      args.each do |arg|
        if arg.is_a?(Prism::KeywordHashNode)
          arg.elements.each do |element|
            next unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

            keywords << [element.key.unescaped.to_s, element.value]
          end
        else
          positional << arg
        end
      end
      [positional, keywords]
    end

    def literal_symbol_node?(node)
      node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::InterpolatedSymbolNode)
    end

    def with_local_scope(block, parameters = [])
      previous_names = @local_names
      @local_names = (collect_local_names(block, {}, parameters) + parameters).uniq
      yield
    ensure
      @local_names = previous_names
    end

    def collect_local_names(node, names = {}, shadowed = [])
      return names.keys unless node

      if node.is_a?(Prism::LocalVariableWriteNode) && !shadowed.include?(node.name.to_s)
        names[node.name.to_s] = true
      end
      if scoped_block_call?(node)
        parameter_names = raw_block_parameter_names(node.block)
        node.child_nodes.each do |child|
          child_shadowed = child.equal?(node.block) ? shadowed + parameter_names : shadowed
          collect_local_names(child, names, child_shadowed)
        end
      else
        node.child_nodes.each { |child| collect_local_names(child, names, shadowed) }
      end
      names.keys
    end

    def scoped_block_call?(node)
      node.is_a?(Prism::CallNode) && node.block &&
        (unqualified_call?(node, :fn) || node.name == :each)
    end

    def raw_block_parameter_names(block)
      required = block.parameters&.parameters&.requireds || []
      required.filter_map do |parameter|
        parameter.name.to_s if parameter.respond_to?(:name)
      end
    end

    def generated_local_name(source_name)
      "ruri--local-#{source_name.tr("_", "-")}"
    end

    def parse_command_body(block)
      statements = block.body&.body || []
      forms = []
      interactive_seen = false
      interactive_problem_reported = false
      docstring_seen = false
      statements.each_with_index do |stmt, index|
        if stmt.is_a?(Prism::LocalVariableWriteNode) ||
           stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode) ||
           stmt.is_a?(Prism::WhileNode) || stmt.is_a?(Prism::UntilNode)
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
        if stmt.name == :each && stmt.receiver
          form = parse_each(stmt)
          forms << form if form
          next
        end
        case stmt.name
        when :doc
          if index.zero? && !docstring_seen
            docstring_seen = true
            if (form = parse_doc_statement(stmt))
              forms << form
            end
          else
            error(stmt.location, "doc is only allowed once, as the first statement of a command or function body")
          end
        when :interactive
          if index <= (docstring_seen ? 1 : 0) && !interactive_seen
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
            error(stmt.location, "interactive must appear exactly once, directly after the optional docstring")
          end
        when :command
          error(stmt.location, "nested command definitions are not supported")
        when :function
          if stmt.block
            error(stmt.location, "nested function definitions are not supported")
          else
            unsupported(stmt)
          end
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

    # The optional first `doc "..."` statement of a command or function
    # body. Returns nil when the node is not a doc statement; records a
    # diagnostic when it is malformed.
    def parse_doc_statement(node)
      return nil unless unqualified_call?(node, :doc)

      if node.block
        error(node.location, "doc does not take a block")
        return nil
      end
      args = node.arguments&.arguments || []
      if args.length != 1
        error(node.location, "doc requires exactly one literal string argument")
        return nil
      end
      ok, text = extract_string(args[0])
      return nil unless ok

      Forms::Docstring.new(text: text)
    end

    def parse_structured_statement(node)
      case node
      when Prism::LocalVariableWriteNode
        parse_local_write(node)
      when Prism::IfNode
        parse_conditional(node, negated: false)
      when Prism::UnlessNode
        parse_conditional(node, negated: true)
      when Prism::WhileNode
        parse_loop(node, negated: false)
      when Prism::UntilNode
        parse_loop(node, negated: true)
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

    def parse_conditional(node, negated:, value_branches: false)
      condition = parse_expression(node.predicate)
      body_parser = value_branches ? method(:parse_value_body) : method(:parse_buffer_statements)
      then_body = body_parser.call(node.statements&.body || [])
      else_body = parse_conditional_else(node, value_branches: value_branches)
      return nil unless condition

      Forms::Conditional.new(
        condition: condition,
        then_body: then_body,
        else_body: else_body,
        negated: negated
      )
    end

    def parse_conditional_else(node, value_branches: false)
      clause = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
      body_parser = value_branches ? method(:parse_value_body) : method(:parse_buffer_statements)
      case clause
      when nil
        []
      when Prism::ElseNode
        body_parser.call(clause.statements&.body || [])
      when Prism::IfNode
        form = parse_conditional(clause, negated: false, value_branches: value_branches)
        form ? [form] : []
      else
        unsupported(clause)
        []
      end
    end

    def parse_loop(node, negated:)
      condition = parse_expression(node.predicate)
      body = parse_buffer_statements(node.statements&.body || [])
      return nil unless condition

      Forms::Loop.new(condition: condition, body: body, negated: negated)
    end

    def parse_each(node)
      if node.arguments
        error(node.location, "each does not take call arguments")
        return nil
      end
      unless node.block
        error(node.location, "each requires a block")
        return nil
      end

      parameters = parse_required_block_parameters(node.block, "each")
      return nil unless parameters
      unless parameters.one?
        error(node.block.location, "each requires exactly one block parameter")
        return nil
      end

      collection = parse_expression(node.receiver)
      return nil unless collection

      previous_names = @local_names
      begin
        @local_names = ((@local_names || []) + parameters).uniq
        body = parse_buffer_statements(node.block.body&.body || [])
      ensure
        @local_names = previous_names
      end
      Forms::Each.new(
        collection: collection,
        parameter: generated_local_name(parameters.first),
        body: body
      )
    end

    def parse_elisp_call(node)
      if node.block&.parameters
        error(block_parameters_location(node.block),
              "el.* body blocks do not take parameters")
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

      body = if node.block
               parse_buffer_statements(node.block.body&.body || [])
             else
               []
             end

      Forms::Call.new(
        name: normalize_elisp_name(source_name),
        arguments: parsed_arguments,
        body: body
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
      when Prism::AndNode
        parse_logical_operation(node, "and")
      when Prism::OrNode
        parse_logical_operation(node, "or")
      when Prism::ParenthesesNode
        expressions = node.body&.body || []
        unless expressions.one?
          return error(node.location,
                       "parentheses must contain exactly one expression")
        end
        parse_expression(expressions.first)
      when Prism::CallNode
        return parse_lambda(node) if unqualified_call?(node, :fn)
        return parse_function_reference(node) if unqualified_call?(node, :function)
        return parse_list_value(node) if unqualified_call?(node, :list)
        return parse_cons_value(node) if unqualified_call?(node, :cons)
        return parse_quote(node) if unqualified_call?(node, :quote)
        return parse_quasiquote(node) if unqualified_call?(node, :quasiquote)
        if unqualified_call?(node, :unquote) || unqualified_call?(node, :splice)
          return error(node.location,
                       "#{node.name} is only allowed inside quasiquote")
        end
        return parse_operator(node) if operator_call?(node)
        return parse_elisp_call(node) if elisp_call?(node)
        # Ruby parses a bare name used before its first textual assignment as
        # a zero-argument call. Ruri locals have command-wide lexical scope,
        # so reinterpret that precise shape when a matching assignment exists.
        return parse_local_read(node) if local_reference_call?(node)

        error(node.location,
              "unsupported expression: use a Ruri expression or an el.* call")
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

    def parse_lambda(node)
      if node.arguments
        error(node.location, "fn takes no arguments; use block parameters")
        return nil
      end
      unless node.block
        error(node.location, "fn requires a do...end or {...} block")
        return nil
      end

      parameters = parse_lambda_parameters(node.block)
      return nil unless parameters

      previous_names = @local_names
      begin
        @local_names = ((@local_names || []) + parameters).uniq
        body = parse_value_body(node.block.body&.body || [])
      ensure
        @local_names = previous_names
      end
      Forms::Lambda.new(
        parameters: parameters.map { |name| generated_local_name(name) },
        body: body
      )
    end

    def parse_lambda_parameters(block)
      parse_required_block_parameters(block, "fn")
    end

    def parse_required_block_parameters(block, construct)
      block_parameters = block.parameters
      return [] unless block_parameters

      parameters = block_parameters.parameters
      required = parameters&.requireds || []
      unsupported_shape =
        block_parameters.locals.any? || parameters.nil? ||
        parameters.optionals.any? || parameters.rest || parameters.posts.any? ||
        parameters.keywords.any? || parameters.keyword_rest || parameters.block
      if unsupported_shape || required.any? { |parameter| !parameter.is_a?(Prism::RequiredParameterNode) }
        error(block_parameters.location,
              "#{construct} supports only required positional block parameters")
        return nil
      end

      names = required.map { |parameter| parameter.name.to_s }
      invalid = names.find { |name| !name.match?(NAME_RE) || name == "t" }
      if invalid
        parameter = required[names.index(invalid)]
        error(parameter.location, "invalid #{construct} parameter name `#{invalid}`")
        return nil
      end
      names
    end

    def operator_call?(node)
      node.receiver && node.call_operator_loc.nil? &&
        (BINARY_OPERATORS.key?(node.name) || UNARY_OPERATORS.key?(node.name))
    end

    def parse_operator(node)
      if node.block
        error(node.location, "operators do not take blocks")
        return nil
      end

      arguments = node.arguments&.arguments || []
      if BINARY_OPERATORS.key?(node.name)
        unless arguments.one?
          error(node.location, "binary operator #{node.name} requires one right operand")
          return nil
        end
        values = [parse_expression(node.receiver), parse_expression(arguments.first)]
        return nil if values.any?(&:nil?)

        Forms::Operation.new(
          name: BINARY_OPERATORS.fetch(node.name),
          arguments: values,
          negated: node.name == :!=
        )
      else
        unless arguments.empty?
          error(node.location, "unary operator #{node.name} takes no right operand")
          return nil
        end
        value = parse_expression(node.receiver)
        return nil unless value

        Forms::Operation.new(
          name: UNARY_OPERATORS.fetch(node.name),
          arguments: [value],
          negated: false
        )
      end
    end

    def parse_logical_operation(node, name)
      left = parse_expression(node.left)
      right = parse_expression(node.right)
      return nil unless left && right

      Forms::Operation.new(name: name, arguments: [left, right], negated: false)
    end

    def parse_function_reference(node)
      if node.block
        error(node.location, "function does not take a block")
        return nil
      end

      arguments = node.arguments&.arguments || []
      unless arguments.one? &&
             (arguments.first.is_a?(Prism::SymbolNode) ||
              arguments.first.is_a?(Prism::InterpolatedSymbolNode))
        error(node.location, "function requires exactly one literal symbol argument")
        return nil
      end

      ok, source_name = extract_symbol(arguments.first)
      return nil unless ok

      name = normalize_elisp_name(source_name)
      unless name.match?(Elisp::SYMBOL_RE)
        error(arguments.first.location, "invalid Emacs Lisp function name `#{source_name}`")
        return nil
      end
      Forms::FunctionReference.new(source_name: source_name, name: name)
    end

    def parse_list_value(node)
      return nil unless reject_expression_block(node, "list")

      elements = (node.arguments&.arguments || []).map { |item| parse_expression(item) }
      elements.any?(&:nil?) ? nil : Forms::ListValue.new(elements: elements)
    end

    def parse_cons_value(node)
      return nil unless reject_expression_block(node, "cons")

      arguments = node.arguments&.arguments || []
      unless arguments.length == 2
        error(node.location, "cons requires exactly two arguments")
        return nil
      end
      car, cdr = arguments.map { |item| parse_expression(item) }
      return nil unless car && cdr

      Forms::ConsValue.new(car: car, cdr: cdr)
    end

    def parse_quote(node)
      return nil unless reject_expression_block(node, "quote")

      argument = single_expression_argument(node, "quote")
      return nil unless argument

      value = parse_quoted_data(argument, quasiquote: false, allow_splice: false)
      value ? Forms::Quote.new(value: value) : nil
    end

    def parse_quasiquote(node)
      return nil unless reject_expression_block(node, "quasiquote")

      argument = single_expression_argument(node, "quasiquote")
      return nil unless argument

      value = parse_quoted_data(argument, quasiquote: true, allow_splice: false)
      value ? Forms::QuasiQuote.new(value: value) : nil
    end

    def reject_expression_block(node, name)
      return true unless node.block

      error(node.location, "#{name} does not take a block")
      false
    end

    def single_expression_argument(node, name)
      arguments = node.arguments&.arguments || []
      return arguments.first if arguments.one?

      error(node.location, "#{name} requires exactly one argument")
    end

    def parse_quoted_data(node, quasiquote:, allow_splice:)
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode,
           Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode,
           Prism::FalseNode, Prism::NilNode,
           Prism::SymbolNode, Prism::InterpolatedSymbolNode
        parse_expression(node)
      when Prism::ArrayNode
        elements = node.elements.map do |element|
          parse_quoted_data(element, quasiquote: quasiquote, allow_splice: true)
        end
        elements.any?(&:nil?) ? nil : Forms::Vector.new(elements: elements)
      when Prism::CallNode
        if unqualified_call?(node, :list)
          return parse_quoted_list(node, quasiquote: quasiquote)
        end
        if unqualified_call?(node, :cons)
          return parse_quoted_cons(node, quasiquote: quasiquote)
        end
        if quasiquote && unqualified_call?(node, :unquote)
          return parse_template_escape(node, splice: false)
        end
        if quasiquote && unqualified_call?(node, :splice)
          unless allow_splice
            return error(node.location,
                         "splice must appear inside a quasiquoted list or vector")
          end
          return parse_template_escape(node, splice: true)
        end

        error(node.location,
              "quoted data supports only literals, arrays, list, and cons")
      else
        error(node.location,
              "unsupported quoted data: #{node.class.name.delete_prefix("Prism::")}")
      end
    end

    def parse_quoted_list(node, quasiquote:)
      return nil unless reject_expression_block(node, "list")

      elements = (node.arguments&.arguments || []).map do |element|
        parse_quoted_data(element, quasiquote: quasiquote, allow_splice: true)
      end
      elements.any?(&:nil?) ? nil : Forms::ListValue.new(elements: elements)
    end

    def parse_quoted_cons(node, quasiquote:)
      return nil unless reject_expression_block(node, "cons")

      arguments = node.arguments&.arguments || []
      unless arguments.length == 2
        error(node.location, "cons requires exactly two arguments")
        return nil
      end
      car = parse_quoted_data(arguments[0], quasiquote: quasiquote, allow_splice: false)
      cdr = parse_quoted_data(arguments[1], quasiquote: quasiquote, allow_splice: false)
      return nil unless car && cdr

      Forms::ConsValue.new(car: car, cdr: cdr)
    end

    def parse_template_escape(node, splice:)
      return nil unless reject_expression_block(node, node.name)

      argument = single_expression_argument(node, node.name)
      return nil unless argument

      value = parse_expression(argument)
      return nil unless value

      splice ? Forms::Splice.new(value: value) : Forms::Unquote.new(value: value)
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

    # Statements shared by nested bodies. Interactive belongs only at the
    # beginning of a command body.
    def parse_value_body(statements)
      return [] if statements.empty?

      forms = parse_buffer_statements(statements[0...-1])
      last = statements.last
      if last.is_a?(Prism::IfNode) || last.is_a?(Prism::UnlessNode)
        form = parse_conditional(
          last,
          negated: last.is_a?(Prism::UnlessNode),
          value_branches: true
        )
        forms << form if form
      elsif value_expression_statement?(last)
        expression = parse_expression(last)
        if expression
          forms << if expression.is_a?(Forms::Call)
                     expression
                   else
                     Forms::ExpressionStatement.new(expression: expression)
                   end
        end
      else
        forms.concat(parse_buffer_statements([last]))
      end
      forms
    end

    def value_expression_statement?(node)
      return false if node.is_a?(Prism::LocalVariableWriteNode) ||
                      node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode) ||
                      node.is_a?(Prism::WhileNode) || node.is_a?(Prism::UntilNode)
      return true unless node.is_a?(Prism::CallNode)
      return false if node.name == :each && node.receiver
      return false if node.receiver.nil? &&
                      %i[interactive command with_current_buffer insert doc].include?(node.name)
      return false if node.receiver.nil? && node.name == :function && node.block

      true
    end

    def parse_buffer_statements(statements)
      forms = []
      statements.each do |stmt|
        if stmt.is_a?(Prism::LocalVariableWriteNode) ||
           stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode) ||
           stmt.is_a?(Prism::WhileNode) || stmt.is_a?(Prism::UntilNode)
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
        if stmt.name == :each && stmt.receiver
          form = parse_each(stmt)
          forms << form if form
          next
        end
        case stmt.name
        when :doc
          error(stmt.location, "doc is only allowed once, as the first statement of a command or function body")
        when :interactive
          error(stmt.location, "interactive is only allowed as the first statement of a command body")
        when :command
          error(stmt.location, "nested command definitions are not supported")
        when :function
          if stmt.block
            error(stmt.location, "nested function definitions are not supported")
          else
            unsupported(stmt)
          end
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
