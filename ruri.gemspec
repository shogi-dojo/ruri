# frozen_string_literal: true

require_relative "lib/ruri"

Gem::Specification.new do |spec|
  spec.name = "ruri"
  spec.version = Ruri::VERSION
  spec.authors = ["shogi-dojo"]
  spec.homepage = "https://github.com/shogi-dojo/ruri"
  spec.license = "MIT"
  spec.summary = "Ruby-shaped scripting for Emacs"
  spec.description =
    "Ruri (瑠璃) compiles Ruby-syntax .ruri files into ordinary, " \
    "dependency-free Emacs Lisp through a validated structural pipeline."

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.glob(
    ["bin/*", "lib/**/*.rb", "lisp/*.el", "examples/*.ruri", "docs/*.md",
     "README.md", "LICENSE*", "CHANGELOG*"]
  ).select { |path| File.file?(path) }
  spec.bindir = "bin"
  spec.executables = ["ruri"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", "~> 1.9"
end
