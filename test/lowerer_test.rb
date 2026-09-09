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

  def test_lowers_calls_and_every_expression_literal
    command = parse(<<~RURI).first
      command :types do
        interactive
        el.message("%S", 1, 2.5, true, false, nil, :hello_world, [1, :two])
      end
    RURI

    call = Ruri::Lowerer.lower([command]).first.items.last

    assert_equal "message", call.items.first.name
    assert_instance_of Ruri::Elisp::String, call.items[1]
    assert_instance_of Ruri::Elisp::Integer, call.items[2]
    assert_instance_of Ruri::Elisp::Float, call.items[3]
    assert_equal %w[t nil nil], call.items.values_at(4, 5, 6).map(&:name)
    assert_equal "hello-world", call.items[7].value.name
    assert_instance_of Ruri::Elisp::List, call.items[8]
    assert_equal "vector", call.items[8].items.first.name
  end
end
