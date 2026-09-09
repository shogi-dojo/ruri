# frozen_string_literal: true

module Ruri
  # Scans raw literal source text for features the Prism AST cannot
  # expose on its own (a future Prism version could constant-fold
  # interpolation into plain string literals, so the node class alone
  # would not catch it). Operates on the exact characters between the
  # quotes; escape-aware.
  module SourceScan
    def self.interpolated?(text)
      escaped = false
      text.length.times do |i|
        c = text[i]
        if escaped
          escaped = false
        elsif c == "\\"
          escaped = true
        elsif c == "#" && text[i + 1] == "{"
          return true
        end
      end
      false
    end
  end
end
