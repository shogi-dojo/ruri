# frozen_string_literal: true

module Ruri
  # A source-level problem with a 1-based position.
  class Diagnostic
    attr_reader :path, :line, :column, :message

    def initialize(path:, line:, column:, message:)
      @path = path
      @line = line
      @column = column
      @message = message
    end

    def to_s
      "#{path}:#{line}:#{column}: #{message}"
    end
  end

  # Raised when a source file cannot be compiled. Carries every diagnostic
  # found during parsing and validation, not just the first.
  class CompileError < StandardError
    attr_reader :diagnostics

    def initialize(diagnostics)
      @diagnostics = diagnostics
      super(diagnostics.map(&:to_s).join("\n"))
    end
  end
end
