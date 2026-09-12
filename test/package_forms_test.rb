# frozen_string_literal: true

require_relative "test_helper"

# Coverage for top-level variable, constant, custom, require, and provide
# forms plus `var` reads.
class PackageFormsTest < Minitest::Test
  include RuriTestHelpers

  def compile_source(source, path: "test.ruri")
    Ruri.compile(source, path: path)
  end

  def test_parses_variable_without_value
    definitions = parse("variable :greeting_text")

    assert_instance_of Ruri::Forms::VariableDefinition, definitions.first
    assert_equal "greeting-text", definitions.first.name
    assert_nil definitions.first.value
    assert_nil definitions.first.docstring
  end

  def test_parses_variable_with_value_and_docstring
    definitions = parse(<<~'RURI')
      variable :greeting_text, "hello", "Greeting used by commands."
    RURI

    definition = definitions.first
    assert_equal "hello", definition.value.value
    assert_equal "Greeting used by commands.", definition.docstring
  end

  def test_parses_constant_with_expression_value
    definitions = parse(<<~RURI)
      constant :limit, 10 + 5, "Upper bound."
    RURI

    assert_instance_of Ruri::Forms::ConstantDefinition, definitions.first
    assert_equal "limit", definitions.first.name
    assert_equal "limit", definitions.first.name
    assert_equal "+", definitions.first.value.name
    assert_equal "Upper bound.", definitions.first.docstring
  end

  def test_emits_defvar_and_defconst_in_conventional_layout
    output = compile_source(<<~RURI)
      variable :greeting_text, "hello", "Greeting used by commands."

      constant :greeting_limit, 3

      variable :declared_only
    RURI

    assert_includes output, <<~ELISP
      (defvar greeting-text "hello"
        "Greeting used by commands.")
    ELISP
    assert_includes output, "(defconst greeting-limit 3)"
    assert_includes output, "(defvar declared-only)"
  end

  def test_variables_and_functions_may_share_a_name
    definitions = parse(<<~RURI)
      function :count_down do
        doc "Counts down."
        0
      end

      variable :count_down, 10, "Current count."
    RURI

    assert_equal %w[function variable], definitions.map { |d| d.class.name.sub("Ruri::Forms::", "").sub("Definition", "").downcase }
  end

  def test_rejects_duplicate_variable_names_across_kinds
    diags = diagnostics_of(<<~RURI)
      variable :greeting_text, "a"

      constant :greeting_text, "b"
    RURI

    assert_equal 1, diags.size
    assert_match(/duplicate constant definition `greeting-text`/, diags.first.message)
    assert_equal 3, diags.first.line
  end

  def test_rejects_constant_without_value
    diag = single_diagnostic("constant :greeting_limit")

    assert_match(/constant requires two or three arguments/, diag.message)
  end

  def test_rejects_variable_with_too_many_arguments
    diag = single_diagnostic('variable :a, 1, "doc", "extra"')

    assert_match(/variable requires one to three arguments/, diag.message)
  end

  def test_rejects_variable_with_receiver_or_block
    diags = diagnostics_of(<<~RURI)
      Foo.variable :a

      variable :b do
      end
    RURI

    assert_equal 2, diags.size
    assert_match(/explicit receiver/, diags.first.message)
    assert_match(/variable does not take a block/, diags.last.message)
  end

  def test_rejects_invalid_variable_names
    diag = single_diagnostic("variable :A_b, 1")

    assert_match(/invalid variable name/, diag.message)
  end

  def test_rejects_variable_docstring_that_is_not_a_string
    diag = single_diagnostic("variable :a, 1, :not_a_doc")

    assert_match(/literal string argument required/, diag.message)
  end
end
