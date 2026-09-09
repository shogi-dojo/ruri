# frozen_string_literal: true

# Entry point for the Ruby compiler test suite:
#   bundle exec ruby -Itest test/compiler_test.rb
require_relative "emitter_test"
require_relative "parser_test"
require_relative "source_scan_test"
