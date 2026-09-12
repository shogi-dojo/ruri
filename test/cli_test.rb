# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class CLITest < Minitest::Test
  include RuriTestHelpers

  def setup
    @tmpdir = Dir.mktmpdir("ruri-cli-test")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def bin
    File.expand_path("../bin/ruri", __dir__)
  end

  def run_cli(*args)
    Open3.capture3(bundle_env, RbConfig.ruby, "-Ilib", bin, *args, chdir: @tmpdir)
  end

  # bin/ruri requires prism; run it through bundler's environment so the
  # same gem versions as the test suite are used.
  def bundle_env
    env = {}
    env["BUNDLE_GEMFILE"] = File.expand_path("../Gemfile", __dir__)
    env
  end

  def write_input(content, name: "hello.ruri")
    path = File.join(@tmpdir, name)
    File.write(path, content)
    path
  end

  def test_successful_compile_exits_zero_and_writes_output
    input = write_input(HELLO_SOURCE)
    output = File.join(@tmpdir, "hello.el")

    stdout, stderr, status = run_cli("compile", input, "--output", output)

    assert_predicate status, :success?, "stderr: #{stderr}"
    assert_empty stderr
    assert_equal Ruri.compile(HELLO_SOURCE, path: input), File.read(output, encoding: "UTF-8")
    assert_empty stdout
  end

  def test_failure_prints_one_based_position_diagnostics_on_stderr
    input = write_input('command :a do
  interactive
  insert(1)
end')
    output = File.join(@tmpdir, "hello.el")

    _stdout, stderr, status = run_cli("compile", input, "--output", output)

    refute_predicate status, :success?
    first_line = stderr.lines.first.chomp
    assert_match(%r{\A#{Regexp.escape(input)}:3:\d+: }, first_line)
    refute File.exist?(output)
  end

  def test_syntax_error_failure_reports_source_positions
    input = write_input("command :a do\n  interactive\n")
    output = File.join(@tmpdir, "hello.el")

    _stdout, stderr, status = run_cli("compile", input, "--output", output)

    refute_predicate status, :success?
    assert_match(/#{Regexp.escape(input)}:\d+:\d+: syntax error/, stderr)
    refute File.exist?(output)
  end

  def test_failed_compile_preserves_previous_output
    input = write_input(HELLO_SOURCE)
    output = File.join(@tmpdir, "hello.el")

    _out, _err, status = run_cli("compile", input, "--output", output)
    assert_predicate status, :success?
    good = File.read(output)

    File.write(input, 'insert("broken")')
    _out, _err, status = run_cli("compile", input, "--output", output)
    refute_predicate status, :success?

    assert_equal good, File.read(output), "a failed compile must not touch existing output"
  end

  def test_successful_compile_overwrites_previous_output
    input = write_input(HELLO_SOURCE)
    output = File.join(@tmpdir, "hello.el")
    File.write(output, "stale content")

    _out, _err, status = run_cli("compile", input, "--output", output)

    assert_predicate status, :success?
    refute_includes File.read(output), "stale"
  end

  def test_handles_paths_with_spaces
    space_dir = File.join(@tmpdir, "my ruri files")
    FileUtils.mkdir_p(space_dir)
    input = File.join(space_dir, "hello.ruri")
    File.write(input, HELLO_SOURCE)
    output = File.join(space_dir, "hello.el")

    _out, err, status = run_cli("compile", input, "--output", output)

    assert_predicate status, :success?, "stderr: #{err}"
    assert File.exist?(output)
  end

  def test_missing_input_file_fails_cleanly
    _out, stderr, status = run_cli("compile", File.join(@tmpdir, "nope.ruri"), "--output", File.join(@tmpdir, "o.el"))

    refute_predicate status, :success?
    assert_match(/nope\.ruri/, stderr)
  end

  def test_usage_errors_exit_nonzero
    [["compile"], ["compile", "in.ruri"], ["compile", "a", "--output"], ["frobnicate"],
     ["compile", "a", "-o", "b"]].each do |argv|
      _out, stderr, status = run_cli(*argv)
      refute_predicate status, :success?, "argv: #{argv.inspect}"
      assert_includes stderr, "usage: ruri compile", "argv: #{argv.inspect}"
    end
  end

  def test_never_loads_or_evals_the_input
    # Static guard complementing the side-effect-free system() fixture:
    # the compiler must not evaluate or dynamically dispatch the input.
    # Comments are stripped first because docs legitimately mention eval.
    lib = File.expand_path("../lib", __dir__)
    Dir.glob(File.join(lib, "**", "*.rb")).sort.each do |file|
      code = File.read(file).gsub(/#.*$/, "")
      [/\beval\b/, /\binstance_eval\b/, /\bclass_eval\b/, /\bmodule_eval\b/,
       /\b__send__\b/, /\bsend\b/, /\bpublic_send\b/, /\bmethod_missing\b/].each do |pattern|
        refute_match pattern, code, "#{file} must not use #{pattern.inspect}"
      end
    end
  end
end
