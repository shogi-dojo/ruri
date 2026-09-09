# frozen_string_literal: true

require_relative "test_helper"

class ElispTest < Minitest::Test
  def test_prints_generic_nested_lists_without_form_specific_rules
    form = Ruri::Elisp.list(
      Ruri::Elisp.symbol("outer"),
      Ruri::Elisp.string("argument"),
      Ruri::Elisp.list(Ruri::Elisp.symbol("inner"), Ruri::Elisp.string("value"))
    )

    assert_equal <<~ELISP.chomp, Ruri::Elisp::Printer.print(form)
      (outer "argument"
        (inner "value"))
    ELISP
  end

  def test_printer_escapes_strings_and_control_characters
    form = Ruri::Elisp.list(
      Ruri::Elisp.symbol("insert"),
      Ruri::Elisp.string("quote\"back\\slash\n\u00015")
    )

    assert_equal '(insert "quote\\"back\\\\slash\\n\\0015")', Ruri::Elisp::Printer.print(form)
  end

  def test_rejects_symbols_that_could_change_lisp_structure
    error = assert_raises(ArgumentError) { Ruri::Elisp.symbol("safe) (error \"oops\"") }

    assert_includes error.message, "invalid Emacs Lisp symbol"
  end

  def test_prints_a_list_in_function_position
    function = Ruri::Elisp.list(
      Ruri::Elisp.symbol("lambda"),
      Ruri::Elisp.list,
      Ruri::Elisp.string("value")
    )
    application = Ruri::Elisp.list(function, Ruri::Elisp.string("ignored"))

    assert_equal <<~ELISP.chomp, Ruri::Elisp::Printer.print(application)
      (
        (lambda () "value")
        "ignored")
    ELISP
  end

  def test_rejects_non_node_list_members
    assert_raises(ArgumentError) { Ruri::Elisp.list(Ruri::Elisp.symbol("insert"), "raw") }
  end

  def test_prints_numbers_quotes_and_vectors
    form = Ruri::Elisp.list(
      Ruri::Elisp.symbol("identity"),
      Ruri::Elisp.vector(
        Ruri::Elisp.integer(-4),
        Ruri::Elisp.float(2.5),
        Ruri::Elisp.quote(Ruri::Elisp.symbol("hello-world"))
      )
    )

    assert_equal "(identity [-4 2.5 'hello-world])", Ruri::Elisp::Printer.print(form)
  end

  def test_rejects_invalid_scalar_values
    assert_raises(ArgumentError) { Ruri::Elisp.integer(1.0) }
    assert_raises(ArgumentError) { Ruri::Elisp.float(Float::INFINITY) }
    assert_raises(ArgumentError) { Ruri::Elisp.vector("raw") }
    assert_raises(ArgumentError) { Ruri::Elisp.quote("raw") }
  end
end
