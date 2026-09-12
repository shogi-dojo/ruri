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

  def test_emits_defcustom_with_docstring_and_type
    output = compile_source(<<~'RURI')
      custom :greeting_style, :plain, "How to greet.", type: :string
    RURI

    assert_includes output, <<~ELISP
      (defcustom greeting-style 'plain
        "How to greet."
        :type 'string)
    ELISP
  end

  def test_emits_defcustom_without_docstring
    output = compile_source(<<~RURI)
      custom :greeting_count, 1, type: :integer
    RURI

    assert_includes output, "(defcustom greeting-count 1\n  :type 'integer)"
  end

  def test_custom_type_accepts_quoted_data
    output = compile_source(<<~'RURI')
      custom :greeting_names, [], type: quote(list(:repeat, :string))
    RURI

    assert_includes output, ":type '(repeat string)"
  end

  def test_rejects_custom_without_value
    diag = single_diagnostic("custom :greeting_style")

    assert_match(/custom requires two or three arguments/, diag.message)
  end

  def test_accepts_multiple_custom_keywords_in_source_order
    output = compile_source(<<~'RURI')
      custom :greeting_style, :plain, "d", group: :faces,
             type: :symbol,
             options: quote(list(:plain, :fancy))
    RURI

    assert_includes output, <<~ELISP
      (defcustom greeting-style 'plain
        "d"
        :group 'faces
        :type 'symbol
        :options '(plain fancy))
    ELISP
  end

  def test_rejects_invalid_custom_keyword_names
    diag = single_diagnostic(<<~'RURI')
      custom :greeting_style, :plain, "d", NotKey: :faces
    RURI

    assert_match(/invalid custom keyword `NotKey`/, diag.message)
  end

  def test_custom_shares_the_variable_namespace
    diags = diagnostics_of(<<~RURI)
      variable :greeting_style, :plain

      custom :greeting_style, :fancy
    RURI

    assert_equal 1, diags.size
    assert_match(/duplicate custom definition `greeting-style`/, diags.first.message)
  end

  def test_require_and_provide_emit_quoted_feature_names
    output = compile_source(<<~RURI)
      require :subr_x

      provide :greeting_pack
    RURI

    assert_includes output, "(require 'subr-x)"
    assert_includes output, "(provide 'greeting-pack)"
  end

  def test_definitions_keep_source_order_for_require_provide
    output = compile_source(<<~RURI)
      require :subr_x

      command :greet_cmd do
        interactive
        insert("hi")
      end

      provide :greeting_pack
    RURI

    require_at = output.index("(require 'subr-x)")
    defun_at = output.index("(defun greet-cmd ()")
    provide_at = output.index("(provide 'greeting-pack)")
    assert require_at < defun_at && defun_at < provide_at
  end

  def test_rejects_feature_form_with_wrong_arguments
    diags = diagnostics_of(<<~RURI)
      require

      provide :a, :b
    RURI

    assert_equal 2, diags.size
    assert_match(/require requires exactly one literal symbol argument/, diags.first.message)
    assert_match(/provide requires exactly one literal symbol argument/, diags.last.message)
  end

  def test_rejects_feature_form_with_block
    diag = single_diagnostic(<<~RURI)
      require :subr_x do
      end
    RURI

    assert_match(/require does not take a block/, diag.message)
  end

  def test_rejects_package_forms_inside_bodies
    diags = diagnostics_of(<<~RURI)
      command :a do
        interactive
        require :subr_x
        provide :a
        variable :x, 1
      end
    RURI

    assert_equal 3, diags.size
    diags.each do |diag|
      assert_match(/is only allowed at the top level of a \.ruri file/, diag.message)
    end
  end


  def test_variable_local_emits_defvar_local
    output = compile_source(<<~'RURI')
      variable_local :greet_prev, nil, "Previous fragment."
    RURI

    assert_includes output, <<~ELISP
      (defvar-local greet-prev nil
        "Previous fragment.")
    ELISP
  end

  def test_assign_emits_setq_with_bare_symbols
    output = compile_source(<<~'RURI')
      command :track_cmd do
        interactive
        assign :greet_prev, "x", :greet_count, 1 + 2
      end
    RURI

    assert_includes output, "(setq greet-prev \"x\" greet-count\n    (+ 1 2))"
  end

  def test_assign_is_rejected_in_bad_shapes
    diags = diagnostics_of(<<~RURI)
      command :a do
        interactive
        assign :x
        assign 1, 2
        assign(:x) { 1 }
      end
    RURI

    assert_equal 3, diags.size
    assert_match(/assign requires name\/value pairs/, diags[0].message)
    assert_match(/assign requires literal symbol variable names/, diags[1].message)
    assert_match(/assign does not take a block/, diags[2].message)
  end

  def test_keyword_emits_self_quoting_symbol
    output = compile_source(<<~RURI)
      command :prop_cmd do
        interactive
        el.message("%S", el.org_element_property(keyword(:begin), :symbol_node))
      end
    RURI

    assert_includes output, %q{(org-element-property :begin 'symbol-node)}
  end

  def test_org_fragtog_conversion_compiles
    source = File.read(File.expand_path("../examples/org-fragtog.ruri", __dir__))
    output = Ruri.compile(source, path: "examples/org-fragtog.ruri")

    assert_includes output, "(provide 'org-fragtog)"
    assert_includes output, "(defvar-local org-fragtog--timer nil"
    assert_includes output, "(org-element-property :begin ruri--local-frag)"
    assert_includes output, ":options '(org-at-table-p org-at-table-el-p org-at-block-p org-at-heading-p)"
    assert_includes output, "(setq org-fragtog-mode\n    (not org-fragtog-mode))"
  end

  def test_var_read_emits_bare_symbol
    output = compile_source(<<~RURI)
      command :show_case_cmd do
        interactive
        style = var :case_fold_search
        el.message("%S" , style)
      end
    RURI

    assert_includes output, "(setq ruri--local-style case-fold-search)"
    assert_includes output, "(message \"%S\" ruri--local-style)"
  end

  def test_var_read_normalizes_underscores
    output = compile_source(<<~RURI)
      command :show_cmd do
        interactive
        el.message("%S", var(:left_margin_width))
      end
    RURI

    assert_includes output, "(message \"%S\" left-margin-width)"
  end

  def test_var_read_works_in_conditions_and_collections
    output = compile_source(<<~RURI)
      command :report_cmd do
        interactive
        if var :auto_fill_mode
          el.message("on")
        end
        total = var :fill_column
        el.message("%S", list(total, 2))
      end
    RURI

    assert_includes output, "(if auto-fill-mode"
    assert_includes output, "(setq ruri--local-total fill-column)"
  end

  def test_rejects_var_reads_with_wrong_arguments
    diags = diagnostics_of(<<~RURI)
      command :a do
        interactive
        el.message("%S", var())
      end
    RURI

    assert_equal 1, diags.size
    assert_match(/var requires exactly one literal symbol argument/, diags.first.message)
  end

  def test_rejects_var_reads_of_reserved_names
    diags = diagnostics_of(<<~RURI)
      command :a do
        interactive
        el.message("%S", var(:nil))
      end
    RURI

    assert_equal 1, diags.size
    assert_match(/invalid variable name `nil`/, diags.first.message)
  end

  def test_rejects_var_reads_with_wrong_arguments
    diags = diagnostics_of(<<~RURI)
      command :a do
        interactive
        el.message("%S", var())
      end
    RURI

    assert_equal 1, diags.size
    assert_match(/var requires exactly one literal symbol argument/, diags.first.message)
  end

  def test_rejects_var_reads_of_reserved_names
    diags = diagnostics_of(<<~RURI)
      command :a do
        interactive
        el.message("%S", var(:nil))
      end
    RURI

    assert_equal 1, diags.size
    assert_match(/invalid variable name `nil`/, diags.first.message)
  end
end
