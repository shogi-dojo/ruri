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
    assert_equal %w[ruri--local-value ruri--local-index], lambda.parameters
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
        callback = fn do |value = nil|
          el.identity(value)
        end
      end
    RURI

    assert_match(/fn supports only required positional block parameters/, diag.message)
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

  def test_rejects_interactive_with_arguments
    diag = single_diagnostic('command :a do
  interactive("p")
end')

    assert_match(/interactive takes no arguments/, diag.message)
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

  def test_rejects_command_block_parameters
    diag = single_diagnostic("command :a do |x|\n  interactive\nend")

    assert_match(/do not take parameters/, diag.message)
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
end
