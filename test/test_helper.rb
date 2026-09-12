# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/ruri"

module RuriTestHelpers
  HELLO_SOURCE = <<~RURI
    command :hello_buffer do
      interactive
      with_current_buffer("*scratch*") do
        insert("Hello from Ruby syntax!\\n")
      end
    end
  RURI

  def parse(source, path: "test.ruri")
    Ruri::Parser.parse(source, path: path)
  end

  def diagnostics_of(source)
    error = assert_raises(Ruri::CompileError) { parse(source) }
    error.diagnostics
  end

  def single_diagnostic(source)
    diags = diagnostics_of(source)
    assert_equal 1, diags.size, "expected exactly one diagnostic, got: #{diags.join(' | ')}"
    diags.first
  end
end
