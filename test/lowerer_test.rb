# frozen_string_literal: true

require_relative "test_helper"

class LowererTest < Minitest::Test
  include RuriTestHelpers

  def test_lowers_language_forms_to_generic_elisp_nodes
    command = parse(HELLO_SOURCE).first

    result = Ruri::Lowerer.lower([command])

    assert_equal [
      Ruri::Elisp.list(
        Ruri::Elisp.symbol("defun"),
        Ruri::Elisp.symbol("hello-buffer"),
        Ruri::Elisp.list,
        Ruri::Elisp.list(Ruri::Elisp.symbol("interactive")),
        Ruri::Elisp.list(
          Ruri::Elisp.symbol("with-current-buffer"),
          Ruri::Elisp.string("*scratch*"),
          Ruri::Elisp.list(
            Ruri::Elisp.symbol("insert"),
            Ruri::Elisp.string("Hello from Ruby syntax!\n")
          )
        )
      )
    ], result
  end

  def test_rejects_unknown_language_forms
    unknown = Data.define.new
    command = Ruri::Forms::Command.new(source_name: "bad", name: "bad", body: [unknown])

    error = assert_raises(ArgumentError) { Ruri::Lowerer.lower([command]) }

    assert_includes error.message, "cannot lower Ruri form"
  end
end
