# frozen_string_literal: true

require_relative "test_helper"

# The byte-identity experiment: a basic hand-written elisp package
# (test/fixtures/greet.el) and its Ruri conversion (examples/greet.ruri)
# must produce byte-identical code. Comments are the one normalization:
# they are not expressible in the language, so comment-only lines are
# dropped from both files before comparison, along with leading blank
# lines left behind by the dropped headers.
class ByteIdentityTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/greet.el", __dir__)
  SOURCE = File.expand_path("../examples/greet.ruri", __dir__)

  def test_greet_package_code_is_byte_identical
    compiled = Ruri.compile(File.read(SOURCE), path: "examples/greet.ruri")

    assert_equal code_section(File.read(FIXTURE)), code_section(compiled)
  end

  def test_compiled_greet_has_ruri_provenance_header
    compiled = Ruri.compile(File.read(SOURCE), path: "examples/greet.ruri")

    assert compiled.start_with?(";;; -*- lexical-binding: t; -*-\n")
    assert_includes compiled.lines[1], "examples/greet.ruri"
  end

  private

  def code_section(text)
    text.lines
        .reject { |line| line.start_with?(";") }
        .join
        .sub(/\A\n+/, "")
  end
end
