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
        Ruri::Elisp.inline_list,
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

  def test_lowers_locals_and_conditionals_to_lexical_elisp
    command = parse(<<~RURI).first
      command :choose do
        interactive
        value = nil
        if el.buffer_modified_p()
          value = "changed"
          el.message("%s", value)
        else
          value = "clean"
        end
        unless value
          el.message("missing")
        end
      end
    RURI

    defun = Ruri::Lowerer.lower([command]).first
    interactive, scope = defun.items.drop(3)
    assert_equal "interactive", interactive.items.first.name
    assert_equal "let", scope.items.first.name
    assert_instance_of Ruri::Elisp::InlineList, scope.items[1]
    assert_equal ["ruri--local-value"], scope.items[1].items.map(&:name)
    assert_equal "setq", scope.items[2].items.first.name

    conditional = scope.items[3]
    assert_equal "if", conditional.items.first.name
    assert_equal "buffer-modified-p", conditional.items[1].items.first.name
    assert_equal "progn", conditional.items[2].items.first.name
    assert_equal "setq", conditional.items[3].items.first.name

    negated = scope.items[4]
    assert_equal "not", negated.items[1].items.first.name
    assert_equal "ruri--local-value", negated.items[1].items[1].name
  end

  def test_lowers_generic_block_forms_and_collects_nested_locals
    command = parse(<<~RURI).first
      command :preserve_point do
        interactive
        result = el.save_excursion do
          position = el.point()
          el.goto_char(el.point_min())
          el.insert(el.number_to_string(position))
        end
        el.message("%S", result)
      end
    RURI

    defun = Ruri::Lowerer.lower([command]).first
    scope = defun.items.last
    assert_equal %w[ruri--local-result ruri--local-position],
                 scope.items[1].items.map(&:name)

    assignment = scope.items[2]
    block_form = assignment.items[2]
    assert_equal "save-excursion", block_form.items.first.name
    assert_equal "setq", block_form.items[1].items.first.name
    assert_equal "goto-char", block_form.items[2].items.first.name
    assert_equal "insert", block_form.items[3].items.first.name
  end
end
