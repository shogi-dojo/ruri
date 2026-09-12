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
    command = Ruri::Forms::Command.new(
      source_name: "bad",
      name: "bad",
      parameters: Ruri::Forms::ParameterList.new(required: [], optionals: [], rest: nil),
      body: [unknown]
    )

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
        if el.buffer_modified_p
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
          position = el.point
          el.goto_char(el.point_min)
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

  def test_lowers_lambdas_and_function_references
    command = parse(<<~RURI).first
      command :callbacks do
        interactive
        prefix = "<"
        callback = fn do |value|
          el.concat(prefix, value, ">")
        end
        el.add_hook(:after_save_hook, function(:callbacks))
      end
    RURI

    scope = Ruri::Lowerer.lower([command]).first.items.last
    lambda = scope.items[3].items[2]
    assert_equal "lambda", lambda.items.first.name
    assert_equal ["ruri--local-value"], lambda.items[1].items.map(&:name)
    assert_equal "concat", lambda.items[2].items.first.name
    assert_equal "ruri--local-prefix", lambda.items[2].items[1].name

    reference = scope.items[4].items.last
    assert_equal %w[function callbacks], reference.items.map(&:name)
  end

  def test_lambda_parameter_assignment_does_not_create_a_command_local
    command = parse(<<~RURI).first
      command :callback do
        interactive
        callback = fn do |value|
          value = "changed"
          el.identity(value)
        end
        el.funcall(callback, "original")
      end
    RURI

    scope = Ruri::Lowerer.lower([command]).first.items.last
    assert_equal ["ruri--local-callback"], scope.items[1].items.map(&:name)
    lambda = scope.items[2].items[2]
    assert_equal "setq", lambda.items[2].items.first.name
    assert_equal "ruri--local-value", lambda.items[2].items[1].name
  end

  def test_lowers_lisp_data_and_templates
    command = parse(<<~RURI).first
      command :data do
        interactive
        tail = list(:b, "c")
        pair = cons(:key, "value")
        literal = quote(list(:alpha, cons(:left, :right)))
        template = quasiquote(list(:head, unquote(el.upcase("x")), splice(tail)))
      end
    RURI

    scope = Ruri::Lowerer.lower([command]).first.items.last
    list = scope.items[2].items[2]
    assert_equal "list", list.items.first.name
    assert_instance_of Ruri::Elisp::Quote, list.items[1]

    cons = scope.items[3].items[2]
    assert_equal "cons", cons.items.first.name

    quote = scope.items[4].items[2]
    assert_instance_of Ruri::Elisp::Quote, quote
    assert_instance_of Ruri::Elisp::DottedPair, quote.value.items.last

    template = scope.items[5].items[2]
    assert_instance_of Ruri::Elisp::QuasiQuote, template
    assert_instance_of Ruri::Elisp::Unquote, template.value.items[1]
    assert_instance_of Ruri::Elisp::Splice, template.value.items[2]
  end

  def test_lowers_operators_and_loops
    command = parse(<<~RURI).first
      command :loops do
        interactive
        count = 0
        while count < 2 && !false
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

    scope = Ruri::Lowerer.lower([command]).first.items.last
    while_loop = scope.items[3]
    assert_equal "while", while_loop.items.first.name
    assert_equal "and", while_loop.items[1].items.first.name
    assert_equal "<", while_loop.items[1].items[1].items.first.name
    assert_equal "not", while_loop.items[1].items[2].items.first.name

    until_loop = scope.items[4]
    assert_equal "not", until_loop.items[1].items.first.name
    assert_equal ">=", until_loop.items[1].items[1].items.first.name

    each = scope.items[5]
    assert_equal "mapc", each.items.first.name
    assert_equal "lambda", each.items[1].items.first.name
    assert_equal ["ruri--local-item"], each.items[1].items[1].items.map(&:name)
    assert_equal "list", each.items[2].items.first.name
  end

  def test_lowers_function_parameters_locals_recursion_and_return_values
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

    factorial, decorate = Ruri::Lowerer.lower(definitions)
    assert_equal "defun", factorial.items.first.name
    assert_equal "factorial", factorial.items[1].name
    assert_equal ["ruri--local-number"], factorial.items[2].items.map(&:name)
    assert_equal "if", factorial.items[3].items.first.name
    recursive_call = factorial.items[3].items[3].items[2]
    assert_equal "factorial", recursive_call.items.first.name

    assert_equal ["ruri--local-value"], decorate.items[2].items.map(&:name)
    scope = decorate.items[3]
    assert_equal "let", scope.items.first.name
    assert_equal ["ruri--local-prefix"], scope.items[1].items.map(&:name)
    assert_equal "concat", scope.items.last.items.first.name
  end

  def test_lowers_docstring_outside_the_locals_let
    command = parse(<<~RURI).first
      command :greet_cmd do
        doc "Greet the world."
        interactive
        message = "hi"
        el.message(message)
      end
    RURI

    form = Ruri::Lowerer.lower([command]).first
    assert_instance_of Ruri::Elisp::Docstring, form.items[3]
    assert_equal "Greet the world.", form.items[3].value.value
    assert_equal "interactive", form.items[4].items.first.name
    scope = form.items[5]
    assert_equal "let", scope.items.first.name
    assert_equal ["ruri--local-message"], scope.items[1].items.map(&:name)
  end

  def test_lowers_function_docstring_outside_the_locals_let
    function = parse(<<~RURI).first
      function :double_it do |number|
        doc "Double NUMBER."
        result = number * 2
        result
      end
    RURI

    form = Ruri::Lowerer.lower([function]).first
    assert_instance_of Ruri::Elisp::Docstring, form.items[3]
    scope = form.items[4]
    assert_equal "let", scope.items.first.name
  end

  def test_lowers_optional_and_rest_parameters
    function = parse(<<~RURI).first
      function :greet do |name, punctuation = "!", *extra|
        el.message(name)
      end
    RURI

    form = Ruri::Lowerer.lower([function]).first
    assert_equal ["ruri--local-name", "&optional", "ruri--local-punctuation",
                  "&rest", "ruri--local-extra"],
                 form.items[2].items.map(&:name)
    default = form.items[3]
    assert_equal "unless", default.items.first.name
    assert_equal "ruri--local-punctuation", default.items[1].name
    assert_equal "setq", default.items[2].items.first.name
    assert_equal "ruri--local-punctuation", default.items[2].items[1].name
    assert_equal "!", default.items[2].items[2].value
  end

  def test_nil_optional_default_emits_no_entry_code
    function = parse(<<~RURI).first
      function :zoom do |size, factor = nil|
        el.message("%S", size)
      end
    RURI

    form = Ruri::Lowerer.lower([function]).first
    assert_equal ["ruri--local-size", "&optional", "ruri--local-factor"],
                 form.items[2].items.map(&:name)
    assert_equal "message", form.items[3].items.first.name
  end

  def test_lowers_lambda_optional_parameters_inside_the_lambda_body
    lambda_form = parse(<<~RURI).first
      function :make do
        fn do |value, factor = 2|
          el.identity(value)
        end
      end
    RURI

    lowered = Ruri::Lowerer.lower([lambda_form]).first
    lambda_node = lowered.items[3]
    assert_equal "lambda", lambda_node.items.first.name
    assert_equal ["ruri--local-value", "&optional", "ruri--local-factor"],
                 lambda_node.items[1].items.map(&:name)
    assert_equal "unless", lambda_node.items[2].items.first.name
  end

  def test_lowers_rescue_to_condition_case
    function = parse(<<~RURI).first
      function :safe do |a|
        begin
          el.message("%S", a)
        rescue :arith_error, :range_error => problem
          el.message("math")
        rescue
          el.message("other")
        else
          el.message("ok")
        end
      end
    RURI

    form = Ruri::Lowerer.lower([function]).first
    body_form = form.items[3].items[2]
    assert_equal "condition-case", body_form.items.first.name
    assert_equal "ruri--local-problem", body_form.items[1].name
    assert_equal "message", body_form.items[2].items.first.name
    specific = body_form.items[3]
    assert_equal ["arith-error", "range-error"], specific.items.first.items.map(&:name)
    assert_equal "message", specific.items[1].items.first.name
    fallback = body_form.items[4]
    assert_equal ["error"], fallback.items.first.items.map(&:name)
    success = body_form.items[5]
    assert_equal ":success", success.items.first.name
  end

  def test_rescue_local_is_declared_in_the_enclosing_let
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

    form = Ruri::Lowerer.lower([function]).first
    scope = form.items[3]
    assert_equal "let", scope.items.first.name
    assert_equal ["ruri--local-problem"], scope.items[1].items.map(&:name)
  end

  def test_lowers_ensure_to_unwind_protect_with_the_body_value
    function = parse(<<~RURI).first
      function :guarded do
        begin
          el.message("work")
        ensure
          el.message("cleanup")
        end
      end
    RURI

    form = Ruri::Lowerer.lower([function]).first
    unwind = form.items[3]
    assert_equal "unwind-protect", unwind.items.first.name
    assert_equal "message", unwind.items[1].items.first.name
    assert_equal "cleanup", unwind.items[2].items[1].value
  end
end
