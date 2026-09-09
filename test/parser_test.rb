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

  def test_rejects_assignments
    diag = single_diagnostic(<<~'RURI')
      command :a do
        interactive
        x = 1
      end
    RURI

    assert_match(/unsupported construct: LocalVariableWriteNode/, diag.message)
    assert_equal 3, diag.line
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
