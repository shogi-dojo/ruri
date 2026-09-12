# frozen_string_literal: true

require_relative "test_helper"

class ParserTest < Minitest::Test
  include RuriTestHelpers

  def test_parses_hello_world_into_internal_forms
    commands = parse(HELLO_SOURCE)

    assert_equal 1, commands.length
    command = commands.first
    assert_equal "hello_buffer", command.source_name
    assert_equal "hello-buffer", command.name
    assert_equal 2, command.body.length

    assert_instance_of Ruri::Forms::Interactive, command.body[0]

    wcb = command.body[1]
    assert_instance_of Ruri::Forms::WithCurrentBuffer, wcb
    assert_equal "*scratch*", wcb.buffer
    assert_equal 1, wcb.body.length

    insert = wcb.body[0]
    assert_instance_of Ruri::Forms::Insert, insert
    assert_equal "Hello from Ruby syntax!\n", insert.text
  end

  def test_parses_multiple_commands
    commands = parse(<<~RURI)
      command :first_cmd do
        interactive
        insert("one")
      end

      command :second_cmd do
        interactive
        insert("two")
      end
    RURI

    assert_equal %w[first-cmd second-cmd], commands.map(&:name)
  end

  def test_parses_top_level_functions_with_parameters_and_value_branches
    definitions = parse(<<~RURI)
      function :factorial do |number|
        if number <= 1
          1
        else
          number * el.factorial(number - 1)
        end
      end

      function :decorate do |value|
        prefix = "<"
        el.concat(prefix, value, ">")
      end
    RURI

    factorial, decorate = definitions
    assert_instance_of Ruri::Forms::FunctionDefinition, factorial
    assert_equal "factorial", factorial.name
    assert_equal ["ruri--local-number"], factorial.parameters.names
    conditional = factorial.body.first
    assert_instance_of Ruri::Forms::Conditional, conditional
    assert_instance_of Ruri::Forms::ExpressionStatement,
                       conditional.then_body.first
    assert_instance_of Ruri::Forms::Operation,
                       conditional.else_body.first.expression

    assert_instance_of Ruri::Forms::FunctionDefinition, decorate
    assert_equal ["ruri--local-value"], decorate.parameters.names
    assert_instance_of Ruri::Forms::LocalWrite, decorate.body.first
    assert_instance_of Ruri::Forms::Call, decorate.body.last
  end

  def test_allows_zero_parameter_and_empty_functions
    function = parse(<<~RURI).first
      function :noop do
      end
    RURI

    assert_instance_of Ruri::Forms::FunctionDefinition, function
    assert_empty function.parameters
    assert_empty function.body
  end

  def test_rejects_name_collisions_between_commands_and_functions
    diag = single_diagnostic(<<~RURI)
      command :same_name do
        interactive
      end

      function :same_name do
        nil
      end
    RURI

    assert_match(/duplicate function definition `same-name`/, diag.message)
    assert_match(/already defined as command/, diag.message)
    assert_equal 5, diag.line
  end

  def test_rejects_keyword_function_parameters
    diag = single_diagnostic(<<~RURI)
      function :keyworded do |value, scale: 1|
        value
      end
    RURI

    assert_match(/function supports only required, optional, and rest positional block parameters/, diag.message)
    assert_equal 1, diag.line
  end

  def test_rejects_post_rest_function_parameters
    diag = single_diagnostic(<<~RURI)
      function :posted do |first, *rest, last|
        first
      end
    RURI

    assert_match(/function supports only required, optional, and rest positional block parameters/, diag.message)
    assert_equal 1, diag.line
  end

  def test_rejects_block_function_parameters
    diag = single_diagnostic(<<~RURI)
      function :blocked do |value, &callback|
        value
      end
    RURI

    assert_match(/function supports only required, optional, and rest positional block parameters/, diag.message)
    assert_equal 1, diag.line
  end

  def test_parses_optional_and_rest_function_parameters
    function = parse(<<~RURI).first
      function :greet do |name, punctuation = "!", *extra|
        el.message(name, punctuation, extra)
      end
    RURI

    parameters = function.parameters
    assert_equal ["ruri--local-name"], parameters.required
    assert_equal 1, parameters.optionals.length
    assert_equal "ruri--local-punctuation", parameters.optionals.first.name
    assert_equal "!", parameters.optionals.first.default.value
    assert_equal "ruri--local-extra", parameters.rest.name
    assert_equal %w[ruri--local-name ruri--local-punctuation ruri--local-extra],
                 parameters.names
  end

  def test_parses_optional_default_referencing_a_parameter
    function = parse(<<~RURI).first
      function :scale do |width, fallback = width|
        el.message("%S", fallback)
      end
    RURI

    default = function.parameters.optionals.first.default
    assert_instance_of Ruri::Forms::LocalRead, default
    assert_equal "ruri--local-width", default.name
  end

  def test_rejects_optional_default_of_a_bare_call
    diag = single_diagnostic(<<~RURI)
      function :broken do |width, fallback = unknown|
        el.message("%S", fallback)
      end
    RURI

    assert_match(/unsupported expression: use a Ruri expression or an el\.\* call/, diag.message)
  end

  def test_rejects_interactive_inside_function
    diag = single_diagnostic(<<~RURI)
      function :bad do
        interactive
      end
    RURI

    assert_match(/interactive is only allowed as the first statement of a command body/, diag.message)
    assert_equal 2, diag.line
  end

  def test_rejects_function_definition_without_a_block
    diag = single_diagnostic("function(:missing)\n")

    assert_match(/function definition requires a do\.\.\.end block/, diag.message)
    assert_equal 1, diag.line
  end

  def test_rejects_nested_function_definitions
    diag = single_diagnostic(<<~RURI)
      function :outer do
        function :inner do
          nil
        end
      end
    RURI

    assert_match(/nested function definitions are not supported/, diag.message)
    assert_equal 2, diag.line
  end

  def test_accepts_quoted_symbols_comments_and_whitespace
    commands = parse(<<~RURI)
      # a leading comment

      command :"hello_buffer" do # trailing comment
        interactive
        insert("one")
      end
      =begin
      block comment
      =end
    RURI

    assert_equal %w[hello-buffer], commands.map(&:name)
  end

  def test_allows_nested_buffer_blocks
    commands = parse(<<~RURI)
      command :nested_cmd do
        interactive
        with_current_buffer("*scratch*") do
          with_current_buffer("*Messages*") do
            insert("deep")
          end
          insert("shallow")
        end
      end
    RURI

    outer = commands.first.body[1]
    assert_equal "*scratch*", outer.buffer
    inner, shallow = outer.body
    assert_equal "*Messages*", inner.buffer
    assert_equal "deep", inner.body[0].text
    assert_equal "shallow", shallow.text
  end

  def test_decodes_ruby_escapes_in_strings
    commands = parse(<<~'RURI')
      command :escape_cmd do
        interactive
        insert("tab\there\nquote\"back\\unicode\u{1F338}")
      end
    RURI

    text = commands.first.body[1].text
    assert_equal "tab\there\nquote\"back\\unicode🌸", text
  end

  def test_accepts_single_quoted_strings
    commands = parse(<<~'RURI')
      command :single_cmd do
        interactive
        insert('no\nescapes')
      end
    RURI

    assert_equal "no\\nescapes", commands.first.body[1].text
  end

  def test_parses_nested_elisp_calls_and_expression_literals
    command = parse(<<~RURI).first
      command :expression_cmd do
        interactive
        el.message("buffer: %s", el.buffer_name, 42, -1.5, true, false, nil,
                   :after_save_hook, [1, :two])
      end
    RURI

    call = command.body[1]
    assert_instance_of Ruri::Forms::Call, call
    assert_equal "message", call.name
    assert_equal %i[string integer float true false nil symbol],
                 call.arguments.values_at(0, 2, 3, 4, 5, 6, 7).map(&:kind)
    assert_equal "buffer-name", call.arguments[1].name
    assert_equal "after-save-hook", call.arguments[7].value
    assert_equal %i[integer symbol], call.arguments[8].elements.map(&:kind)
  end

  def test_parses_lambdas_captures_and_function_references
    command = parse(<<~RURI).first
      command :callbacks do
        interactive
        prefix = "<"
        callback = fn do |value, index|
          el.message("%s%s:%s", prefix, value, index)
        end
        el.add_hook(:after_save_hook, function(:callbacks))
      end
    RURI

    lambda = command.body[2].value
    assert_instance_of Ruri::Forms::Lambda, lambda
    assert_equal %w[ruri--local-value ruri--local-index], lambda.parameters.names
    assert_equal "ruri--local-prefix", lambda.body.first.arguments[1].name
    assert_equal "ruri--local-value", lambda.body.first.arguments[2].name

    reference = command.body[3].arguments.last
    assert_instance_of Ruri::Forms::FunctionReference, reference
    assert_equal "callbacks", reference.name
  end

  def test_parses_lists_cons_quote_and_quasiquote
    command = parse(<<~RURI).first
      command :data do
        interactive
        tail = list("b", "c")
        pair = cons(:key, "value")
        literal = quote(list(:alpha, cons(:left, :right)))
        template = quasiquote(list(:head, unquote(el.upcase("x")), splice(tail)))
      end
    RURI

    list = command.body[1].value
    assert_instance_of Ruri::Forms::ListValue, list
    assert_equal %i[string string], list.elements.map(&:kind)

    cons = command.body[2].value
    assert_instance_of Ruri::Forms::ConsValue, cons
    assert_equal :symbol, cons.car.kind

    quote = command.body[3].value
    assert_instance_of Ruri::Forms::Quote, quote
    assert_instance_of Ruri::Forms::ConsValue, quote.value.elements.last

    quasiquote = command.body[4].value
    assert_instance_of Ruri::Forms::QuasiQuote, quasiquote
    assert_instance_of Ruri::Forms::Unquote, quasiquote.value.elements[1]
    assert_instance_of Ruri::Forms::Splice, quasiquote.value.elements[2]
  end

  def test_rejects_template_escapes_outside_quasiquote
    %w[unquote splice].each do |name|
      diag = single_diagnostic(<<~RURI)
        command :data do
          interactive
          value = #{name}(1)
        end
      RURI

      assert_match(/#{name} is only allowed inside quasiquote/, diag.message)
      assert_equal 3, diag.line
    end
  end

  def test_rejects_top_level_splice_in_quasiquote
    diag = single_diagnostic(<<~RURI)
      command :data do
        interactive
        values = list(1, 2)
        template = quasiquote(splice(values))
      end
    RURI

    assert_match(/splice must appear inside a quasiquoted list or vector/, diag.message)
    assert_equal 4, diag.line
  end

  def test_rejects_runtime_expressions_inside_plain_quote
    diag = single_diagnostic(<<~RURI)
      command :data do
        interactive
        value = "dynamic"
        literal = quote(list(:prefix, value))
      end
    RURI

    assert_match(/unsupported quoted data: LocalVariableReadNode/, diag.message)
    assert_equal 4, diag.line
  end

  def test_lambda_parameters_do_not_escape_the_lambda
    diag = single_diagnostic(<<~RURI)
      command :callbacks do
        interactive
        callback = fn do |value|
          value = "inside"
          el.identity(value)
        end
        el.message("%S", value)
      end
    RURI

    assert_match(/use a Ruri expression or an el\.\* call/, diag.message)
    assert_equal 7, diag.line
  end

  def test_rejects_unsupported_lambda_parameters
    diag = single_diagnostic(<<~RURI)
      command :callbacks do
        interactive
        callback = fn do |value = nil, key: 1|
          el.identity(value)
        end
      end
    RURI

    assert_match(/fn supports only required, optional, and rest positional block parameters/, diag.message)
    assert_equal 3, diag.line
  end

  def test_rejects_invalid_function_reference
    diag = single_diagnostic(<<~RURI)
      command :callbacks do
        interactive
        el.add_hook(:after_save_hook, function("callbacks"))
      end
    RURI

    assert_match(/function requires exactly one literal symbol argument/, diag.message)
    assert_equal 3, diag.line
  end

  def test_normalizes_predicate_function_names
    call = parse(<<~RURI).first.body[1]
      command :predicate_cmd do
        interactive
        el.buffer_live?(el.current_buffer)
      end
    RURI

    assert_equal "buffer-live?", call.name
    assert_equal "current-buffer", call.arguments.first.name
  end

  def test_zero_argument_elisp_calls_prefer_bare_ruby_style_but_accept_parentheses
    bare = parse(<<~RURI).first.body[1]
      command :bare do
        interactive
        el.buffer_name
      end
    RURI
    parenthesized = parse(<<~RURI).first.body[1]
      command :parenthesized do
        interactive
        el.buffer_name()
      end
    RURI

    assert_equal bare, parenthesized
    assert_empty bare.arguments
  end

  def test_parses_block_body_on_elisp_calls
    command = parse(<<~RURI).first
      command :block_form do
        interactive
        el.save_excursion do
          position = el.point
          el.goto_char(el.point_min)
          if position
            el.message("moved")
          end
        end
      end
    RURI

    call = command.body[1]
    assert_instance_of Ruri::Forms::Call, call
    assert_equal "save-excursion", call.name
    assert_empty call.arguments
    assert_instance_of Ruri::Forms::LocalWrite, call.body[0]
    assert_instance_of Ruri::Forms::Call, call.body[1]
    assert_instance_of Ruri::Forms::Conditional, call.body[2]
  end

  def test_rejects_parameters_on_elisp_body_blocks
    diag = single_diagnostic(<<~RURI)
      command :a do
        interactive
        el.save_excursion do |value|
          el.message("%S", value)
        end
      end
    RURI

    assert_match(/el\.\* body blocks do not take parameters/, diag.message)
    assert_equal 3, diag.line
  end

  def test_rejects_unqualified_calls_inside_elisp_arguments
    diag = single_diagnostic(<<~RURI)
      command :a do
        interactive
        el.message(buffer_name())
      end
    RURI

    assert_match(/use a Ruri expression or an el\.\* call/, diag.message)
  end

  def test_rejects_keyword_arguments
    diag = single_diagnostic(<<~RURI)
      command :a do
        interactive
        el.message(value: 1)
      end
    RURI

    assert_match(/unsupported expression: KeywordHashNode/, diag.message)
  end

  def test_rejects_safe_navigation_on_elisp_namespace
    diag = single_diagnostic(<<~RURI)
      command :a do
        interactive
        el&.message("x")
      end
    RURI

    assert_match(/explicit receiver/, diag.message)
  end

  def test_reports_syntax_errors_with_one_based_positions
    diags = diagnostics_of("command :a do\n  interactive\n")

    assert_operator diags.size, :>=, 1
    diags.each do |diag|
      assert_match(/\Asyntax error: /, diag.message)
      assert_operator diag.line, :>=, 1
      assert_operator diag.column, :>=, 1
    end
  end

  def test_rejects_insert_outside_command
    diag = single_diagnostic('insert("top")')

    assert_equal "test.ruri:1:1", "#{diag.path}:#{diag.line}:#{diag.column}"
    assert_match(/unsupported construct: method call `insert`/, diag.message)
  end

  def test_rejects_executable_top_level_expression
    diag = single_diagnostic("1 + 1")

    assert_equal 1, diag.line
    assert_match(/unsupported construct/, diag.message)
  end

  def test_rejects_system_call_without_side_effect
    target = File.join(Dir.tmpdir, "ruri_negative_fixture_should_not_exist")
    FileUtils.rm_f(target)

    diag = single_diagnostic("system(\"touch #{target}\")")

    assert_match(/unsupported construct: method call `system`/, diag.message)
    refute File.exist?(target), "the input must never be executed"
  end

  def test_rejects_explicit_receiver
    diag = single_diagnostic('command :a do
  interactive
  Kernel.insert("x")
end')

    assert_match(/explicit receiver/, diag.message)
    assert_equal 3, diag.line
  end

  def test_rejects_interpolation_of_constants
    diag = single_diagnostic(<<~'RURI')
      command :a do
        interactive
        insert("a#{1+1}b")
      end
    RURI

    assert_match(/interpolated or adjacent string literals are not supported/, diag.message)
    assert_equal 3, diag.line
  end

  def test_rejects_variable_interpolation
    diag = single_diagnostic(<<~'RURI')
      command :a do
        interactive
        insert("v=#{x}")
      end
    RURI

    assert_match(/interpolated or adjacent string literals are not supported/, diag.message)
  end

  def test_parses_lexical_locals_and_conditionals
    command = parse(<<~RURI).first
      command :describe do
        interactive
        name = el.buffer_name
        if name
          el.message("Buffer: %s", name)
        elsif false
          name = "fallback"
        else
          el.message("No buffer")
        end
        unless el.string_empty_p(name)
          el.message("named")
        end
      end
    RURI

    write, conditional, negated = command.body.drop(1)
    assert_instance_of Ruri::Forms::LocalWrite, write
    assert_equal "name", write.source_name
    assert_equal "ruri--local-name", write.name
    assert_instance_of Ruri::Forms::Call, write.value

    assert_instance_of Ruri::Forms::Conditional, conditional
    assert_equal false, conditional.negated
    assert_instance_of Ruri::Forms::LocalRead, conditional.condition
    assert_equal "ruri--local-name", conditional.condition.name
    assert_instance_of Ruri::Forms::Conditional, conditional.else_body.first
    assert_instance_of Ruri::Forms::LocalWrite,
                       conditional.else_body.first.then_body.first

    assert_instance_of Ruri::Forms::Conditional, negated
    assert_equal true, negated.negated
    assert_instance_of Ruri::Forms::LocalRead,
                       negated.condition.arguments.first
  end

  def test_parses_boolean_comparison_and_arithmetic_operators
    command = parse(<<~RURI).first
      command :operators do
        interactive
        a = 2
        b = 3
        add = a + b
        subtract = a - b
        multiply = a * b
        divide = b / a
        modulo = b % a
        power = a ** b
        compare = a < b && a <= b && b > a && b >= a
        equality = a == b || a != b
        negate = !equality
        negative = -a
        positive = +a
      end
    RURI

    operations = command.body.drop(3).map(&:value)
    assert_equal ["+", "-", "*", "/", "mod", "expt"],
                 operations.first(6).map(&:name)
    assert_equal "and", operations[6].name
    assert_equal "or", operations[7].name
    assert_equal true, operations[7].arguments.last.negated
    assert_equal %w[not - identity], operations.last(3).map(&:name)
  end

  def test_parses_while_until_and_each
    command = parse(<<~RURI).first
      command :loops do
        interactive
        count = 0
        while count < 2
          count = count + 1
        end
        until count >= 3
          count = count + 1
        end
        list(1, 2).each do |item|
          count = count + item
        end
      end
    RURI

    while_loop, until_loop, each = command.body.drop(2)
    assert_instance_of Ruri::Forms::Loop, while_loop
    assert_equal false, while_loop.negated
    assert_instance_of Ruri::Forms::Loop, until_loop
    assert_equal true, until_loop.negated
    assert_instance_of Ruri::Forms::Each, each
    assert_equal "ruri--local-item", each.parameter
    assert_instance_of Ruri::Forms::ListValue, each.collection
  end

  def test_each_parameter_does_not_escape_its_block
    diag = single_diagnostic(<<~RURI)
      command :loops do
        interactive
        list(1).each do |item|
          item = item + 1
        end
        el.message("%S", item)
      end
    RURI

    assert_match(/use a Ruri expression or an el\.\* call/, diag.message)
    assert_equal 6, diag.line
  end

  def test_each_requires_exactly_one_required_parameter
    diag = single_diagnostic(<<~RURI)
      command :loops do
        interactive
        list(1).each do
          el.message("missing")
        end
      end
    RURI

    assert_match(/each requires exactly one block parameter/, diag.message)
    assert_equal 3, diag.line
  end

  def test_local_scope_covers_the_whole_command_and_nested_blocks
    command = parse(<<~RURI).first
      command :scope do
        interactive
        el.message("%S", later)
        if true
          later = "set"
        end
        with_current_buffer("*scratch*") do
          el.message("%s", later)
        end
      end
    RURI

    first_read = command.body[1].arguments.last
    nested_read = command.body[3].body.first.arguments.last
    assert_equal "ruri--local-later", first_read.name
    assert_equal first_read, nested_read
  end

  def test_does_not_leak_locals_between_commands
    diag = single_diagnostic(<<~RURI)
      command :writer do
        interactive
        value = 1
      end

      command :reader do
        interactive
        el.message("%S", value)
      end
    RURI

    assert_match(/use a Ruri expression or an el\.\* call/, diag.message)
    assert_equal 8, diag.line
  end

  def test_rejects_compound_assignment
    diag = single_diagnostic(<<~RURI)
      command :a do
        interactive
        value = 1
        value += 1
      end
    RURI

    assert_match(/unsupported construct: LocalVariableOperatorWriteNode/, diag.message)
    assert_equal 4, diag.line
  end

  def test_rejects_reserved_and_invalid_local_names
    %w[t _hidden].each do |name|
      diag = single_diagnostic(<<~RURI)
        command :a do
          interactive
          #{name} = 1
        end
      RURI

      assert_match(/invalid local variable name `#{name}`/, diag.message)
      assert_equal 3, diag.line
    end
  end

  def test_rejects_interactive_inside_conditional
    diag = single_diagnostic(<<~RURI)
      command :a do
        interactive
        if true
          interactive
        end
      end
    RURI

    assert_match(/interactive is only allowed as the first statement of a command body/, diag.message)
    assert_equal 4, diag.line
  end

  def test_rejects_heredocs
    diag = single_diagnostic(<<~'RURI')
      command :a do
        interactive
        insert(<<~EOS)
          hi
        EOS
      end
    RURI

    assert_match(/heredocs are not supported/, diag.message)
  end

  def test_rejects_percent_string_forms
    diag = single_diagnostic('command :a do
  interactive
  insert(%q(hi))
end')

    assert_match(/unsupported string literal form/, diag.message)
  end

  def test_rejects_adjacent_string_literals
    diag = single_diagnostic('command :a do
  interactive
  insert("a" "b")
end')

    assert_match(/interpolated or adjacent string literals are not supported/, diag.message)
  end

  def test_rejects_character_literal_argument
    diag = single_diagnostic(<<~'RURI')
      command :a do
        interactive
        insert(?a)
      end
    RURI

    assert_match(/unsupported string literal form/, diag.message)
  end

  def test_rejects_missing_interactive
    diag = single_diagnostic('command :a do
  insert("x")
end')

    assert_match(/command body must start with interactive/, diag.message)
    assert_equal 2, diag.line
  end

  def test_rejects_interactive_not_first
    diag = single_diagnostic('command :a do
  insert("x")
  interactive
end')

    assert_equal 3, diag.line
    assert_match(/interactive must appear exactly once/, diag.message)
  end

  def test_rejects_duplicate_interactive
    diag = single_diagnostic('command :a do
  interactive
  interactive
end')

    assert_equal 3, diag.line
  end

  def test_rejects_interactive_with_multiple_arguments
    diags = diagnostics_of(<<~'RURI')
      command :a do
        interactive "p", "r"
      end
    RURI

    assert_equal 1, diags.size
    assert_match(/interactive takes at most one literal string argument/, diags[0].message)
  end

  def test_rejects_interactive_with_non_string_spec
    diags = diagnostics_of(<<~RURI)
      command :a do
        interactive :p
      end
    RURI

    assert_equal 1, diags.size
    assert_match(/literal string argument required/, diags[0].message)
  end

  def test_parses_command_parameters_and_interactive_spec
    command = parse(<<~RURI).first
      command :jump_cmd do |argument, raw_prefix = nil|
        doc "Jump to ARGUMENT."
        interactive "P"
        el.message("%s %s", argument, raw_prefix)
      end
    RURI

    assert_equal ["ruri--local-argument", "ruri--local-raw-prefix"],
                 command.parameters.names
    interactive = command.body[1]
    assert_instance_of Ruri::Forms::Interactive, interactive
    assert_equal "P", interactive.spec.value
  end

  def test_parses_interactive_without_spec
    command = parse(<<~RURI).first
      command :plain_cmd do
        interactive
        insert("hi")
      end
    RURI

    assert_nil command.body[0].spec
  end

  def test_rejects_interactive_inside_buffer_block
    diag = single_diagnostic('command :a do
  interactive
  with_current_buffer("*scratch*") do
    interactive
  end
end')

    assert_match(/interactive is only allowed as the first statement of a command body/, diag.message)
    assert_equal 4, diag.line
  end

  def test_rejects_command_without_block
    diag = single_diagnostic("command :a")

    assert_match(/command requires a do\.\.\.end block/, diag.message)
  end

  def test_rejects_command_with_two_symbols
    diag = single_diagnostic("command :a, :b do\n  interactive\nend")

    assert_match(/exactly one literal symbol argument/, diag.message)
  end

  def test_rejects_command_with_string_name
    diag = single_diagnostic("command \"a\" do\n  interactive\nend")

    assert_match(/exactly one literal symbol argument/, diag.message)
  end

  def test_rejects_reserved_command_parameter_name
    diag = single_diagnostic("command :a do |t|\n  interactive\nend")

    assert_match(/invalid command parameter name `t`/, diag.message)
    assert_equal 1, diag.line
  end

  def test_parses_begin_rescue_with_conditions_binding_and_else
    function = parse(<<~RURI).first
      function :safe do |a, b|
        begin
          el.message("%S", a)
        rescue :arith_error => problem
          el.message("math")
        rescue
          el.message("other")
        else
          el.message("ok")
        end
      end
    RURI

    rescue_form = function.body.first.expression
    assert_instance_of Ruri::Forms::Rescue, rescue_form
    assert_equal "ruri--local-problem", rescue_form.var
    assert_equal 2, rescue_form.clauses.length
    assert_equal ["arith-error"], rescue_form.clauses[0][0]
    assert_equal ["error"], rescue_form.clauses[1][0]
    assert_equal 1, rescue_form.body.length
    assert_equal 1, rescue_form.else_body.length
  end

  def test_parses_catch_and_throw_with_symbol_tags
    function = parse(<<~RURI).first
      function :seek do |limit|
        found = catch(:found_value) do
          throw :found_value, limit
        end
        el.message("%S", found)
      end
    RURI

    catch_form = function.body.first.value
    assert_instance_of Ruri::Forms::Catch, catch_form
    assert_equal "found-value", catch_form.tag
    throw_form = catch_form.body.first.expression
    assert_instance_of Ruri::Forms::Throw, throw_form
    assert_equal "found-value", throw_form.tag
    assert_equal "ruri--local-limit", throw_form.value.name
  end

  def test_parses_break_next_and_return
    function = parse(<<~RURI).first
      function :scan do |cap|
        total = 0
        while total < cap
          total = total + 1
          break if total == 3
        end
        list(1, 0, 2).each do |item|
          next if item == 0
        end
        return total
      end
    RURI

    loop_form = function.body[1]
    assert_instance_of Ruri::Forms::Loop, loop_form
    assert_instance_of Ruri::Forms::Break, loop_form.body.last.then_body.first
    each_form = function.body[2]
    assert_instance_of Ruri::Forms::Next, each_form.body.first.then_body.first
    assert_instance_of Ruri::Forms::Return, function.body[3]
    assert_equal "ruri--local-total", function.body[3].value.name
  end

  def test_rejects_break_outside_loop
    diag = single_diagnostic(<<~RURI)
      function :stray do
        break
      end
    RURI

    assert_match(/`break` cannot cross a fn boundary/, diag.message)
    assert_equal 2, diag.line
  end

  def test_rejects_break_crossing_fn_boundary
    diag = single_diagnostic(<<~RURI)
      command :outer do
        interactive
        while true
          callback = fn do
            break
          end
          el.identity(callback)
        end
      end
    RURI

    assert_match(/`break` cannot cross a fn boundary/, diag.message)
    assert_equal 5, diag.line
  end

  def test_rejects_exit_with_multiple_values
    diags = diagnostics_of(<<~RURI)
      command :multi do
        interactive
        while true
          break 1, 2
        end
      end
    RURI

    assert_equal 1, diags.size
    assert_match(/break takes at most one value/, diags[0].message)
  end

  def test_rejects_malformed_catch_and_throw
    diags = diagnostics_of(<<~RURI)
      function :bad do
        catch(:a)
        catch
        throw :a
        throw :a, 1, 2
        throw "text", 1
      end
    RURI

    assert_equal 5, diags.size
    assert_match(/catch requires a do\.\.\.end block/, diags[0].message)
    assert_match(/catch requires a do\.\.\.end block/, diags[1].message)
    assert_match(/throw requires a tag symbol and a value expression/, diags[2].message)
    assert_match(/throw requires a tag symbol and a value expression/, diags[3].message)
    assert_match(/literal symbol argument required/, diags[4].message)
  end

  def test_rescue_variable_is_readable_after_the_block
    function = parse(<<~RURI).first
      function :leaky do
        begin
          el.message("body")
        rescue => problem
          el.message("caught")
        end
        el.message("%S", problem)
      end
    RURI

    trailing = function.body.last
    assert_equal "ruri--local-problem", trailing.arguments[1].name
  end

  def test_rejects_begin_without_rescue_or_ensure
    diag = single_diagnostic(<<~RURI)
      function :bare do
        begin
          el.message("x")
        end
      end
    RURI

    assert_match(/begin requires a rescue or ensure clause/, diag.message)
    assert_equal 2, diag.line
  end

  def test_rejects_non_symbol_rescue_condition
    diag = single_diagnostic(<<~RURI)
      function :typed do
        begin
          el.message("x")
        rescue 1
          el.message("caught")
        end
      end
    RURI

    assert_match(/literal symbol argument required/, diag.message)
    assert_equal 4, diag.line
  end

  def test_rejects_invalid_rescue_condition_name
    diag = single_diagnostic(<<~RURI)
      function :typed do
        begin
          el.message("x")
        rescue :Not_A_Condition
          el.message("caught")
        end
      end
    RURI

    assert_match(/invalid rescue condition `Not_A_Condition`/, diag.message)
  end

  def test_rejects_mismatched_rescue_variables
    diag = single_diagnostic(<<~RURI)
      function :mixed do
        begin
          el.message("x")
        rescue :arith_error => first
          el.message("math")
        rescue => second
          el.message("other")
        end
      end
    RURI

    assert_match(/all rescue clauses must bind the same variable name/, diag.message)
  end

  def test_parses_begin_ensure_with_and_without_rescue
    definitions = parse(<<~RURI)
      function :guarded do
        begin
          el.message("work")
        ensure
          el.message("cleanup")
        end
      end

      function :both do |a|
        begin
          el.message("%S", a)
        rescue :arith_error
          el.message("math")
        ensure
          el.message("cleanup")
        end
      end
    RURI

    plain = definitions[0].body.first.expression
    assert_instance_of Ruri::Forms::Ensure, plain
    assert_equal 1, plain.body.length
    assert_equal 1, plain.ensure_body.length

    composed = definitions[1].body.first.expression
    assert_instance_of Ruri::Forms::Ensure, composed
    assert_equal 1, composed.body.length
    assert_instance_of Ruri::Forms::Rescue, composed.body.first
    assert_equal 1, composed.body.first.clauses.length
  end

  def test_rejects_nested_command
    diag = single_diagnostic('command :a do
  interactive
  command :b do
    interactive
  end
end')

    assert_match(/nested command definitions are not supported/, diag.message)
    assert_equal 3, diag.line
  end

  def test_rejects_command_with_receiver
    diag = single_diagnostic("Foo.command :a do\n  interactive\nend")

    assert_match(/explicit receiver/, diag.message)
  end

  def test_rejects_insert_with_block
    diag = single_diagnostic('command :a do
  interactive
  insert("x") do
  end
end')

    assert_match(/insert does not take a block/, diag.message)
  end

  def test_rejects_insert_with_two_arguments
    diag = single_diagnostic('command :a do
  interactive
  insert("a", "b")
end')

    assert_match(/exactly one literal string argument/, diag.message)
  end

  def test_rejects_insert_with_non_string_argument
    diag = single_diagnostic('command :a do
  interactive
  insert(1)
end')

    assert_match(/literal string argument required/, diag.message)
  end

  def test_rejects_buffer_block_without_block
    diag = single_diagnostic('command :a do
  interactive
  with_current_buffer("*scratch*")
end')

    assert_match(/with_current_buffer requires a do\.\.\.end block/, diag.message)
  end

  def test_rejects_empty_buffer_block
    diag = single_diagnostic('command :a do
  interactive
  with_current_buffer("*scratch*") do
  end
end')

    assert_match(/nonempty do\.\.\.end block/, diag.message)
  end

  def test_rejects_buffer_block_parameters
    diag = single_diagnostic('command :a do
  interactive
  with_current_buffer("*scratch*") do |b|
    insert("x")
  end
end')

    assert_match(/do not take parameters/, diag.message)
  end

  def test_rejects_duplicate_commands
    diags = diagnostics_of(<<~RURI)
      command :a_b do
        interactive
        insert("1")
      end

      command :a_b do
        interactive
        insert("2")
      end
    RURI

    assert_equal 1, diags.size
    assert_match(/duplicate command definition `a-b`/, diags.first.message)
    assert_equal 6, diags.first.line
  end

  def test_rejects_invalid_command_names
    ["A", "_a", "aB"].each do |name|
      diag = single_diagnostic("command :#{name} do\n  interactive\nend")
      assert_match(/invalid command name/, diag.message)
    end
  end

  def test_rejects_names_ruby_syntax_itself_rejects
    ["1a", "a-b"].each do |name|
      diags = diagnostics_of("command :#{name} do\n  interactive\nend")
      assert_operator diags.size, :>=, 1
    end
  end

  def test_collects_multiple_diagnostics_across_commands
    diags = diagnostics_of(<<~RURI)
      command :a do
        insert("missing interactive")
      end

      command :b do
        interactive
        insert(1)
      end
    RURI

    assert_equal 2, diags.size
  end

  def test_accepts_empty_file
    assert_equal [], parse("")
    assert_equal [], parse("# only a comment\n")
  end

  def test_parses_docstring_in_command_body
    commands = parse(<<~RURI)
      command :greet_cmd do
        doc "Greet the world."
        interactive
        insert("hi")
      end
    RURI

    assert_instance_of Ruri::Forms::Docstring, commands.first.body[0]
    assert_equal "Greet the world.", commands.first.body[0].text
    assert_instance_of Ruri::Forms::Interactive, commands.first.body[1]
  end

  def test_parses_docstring_in_function_body
    functions = parse(<<~RURI)
      function :double_it do |number|
        doc "Double NUMBER."
        number * 2
      end
    RURI

    assert_equal "Double NUMBER.", functions.first.body[0].text
  end

  def test_rejects_docstring_not_first
    diag = single_diagnostic(<<~RURI)
      command :a do
        interactive
        doc "Late."
      end
    RURI

    assert_equal 3, diag.line
    assert_match(/doc is only allowed once, as the first statement/, diag.message)
  end

  def test_rejects_second_docstring
    diags = diagnostics_of(<<~RURI)
      command :a do
        doc "First."
        doc "Second."
        interactive
      end
    RURI

    assert_equal 2, diags.size
    assert_equal 3, diags.first.line
    assert_match(/doc is only allowed once/, diags.first.message)
  end

  def test_rejects_docstring_with_non_string_argument
    diag = single_diagnostic(<<~RURI)
      command :a do
        doc(:not_a_string)
        interactive
      end
    RURI

    assert_match(/literal string argument required/, diag.message)
  end

  def test_rejects_command_without_interactive_after_docstring
    diag = single_diagnostic(<<~RURI)
      command :a do
        doc "Doc only."
        insert("x")
      end
    RURI

    assert_match(/command body must start with interactive/, diag.message)
  end

  def test_rejects_docstring_outside_definitions
    diag = single_diagnostic(<<~RURI)
      command :a do
        interactive
        with_current_buffer("*scratch*") do
          doc "Nested."
        end
      end
    RURI

    assert_match(/doc is only allowed once, as the first statement/, diag.message)
  end
end
