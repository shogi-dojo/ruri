# frozen_string_literal: true

module Ruri
  VERSION = "0.12.0"
end

require_relative "ruri/diagnostic"
require_relative "ruri/forms"
require_relative "ruri/elisp"
require_relative "ruri/lowerer"
require_relative "ruri/printer"
require_relative "ruri/emitter"
require_relative "ruri/source_scan"
require_relative "ruri/parser"

module Ruri
  # Parses +source+ and emits the generated Emacs Lisp text.
  # Raises Ruri::CompileError when the source violates the contract.
  def self.compile(source, path:)
    definitions = Parser.parse(source, path: path)
    Emitter.emit(definitions, source_path: path)
  end
end
