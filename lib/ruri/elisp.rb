# frozen_string_literal: true

module Ruri
  # A small, safe representation of Emacs Lisp data. Language-specific
  # lowering produces these nodes; Printer is solely responsible for turning
  # them into source text.
  module Elisp
    SYMBOL_RE = /\A[a-zA-Z0-9+*\/<>=!?$%_&~^:.@-]+\z/.freeze

    Symbol = Data.define(:name)
    String = Data.define(:value)
    List = Data.define(:items)

    module_function

    def symbol(name)
      name = name.to_s
      unless name.match?(SYMBOL_RE)
        raise ArgumentError, "invalid Emacs Lisp symbol: #{name.inspect}"
      end

      Symbol.new(name: name.freeze)
    end

    def string(value)
      String.new(value: value.to_s.freeze)
    end

    def list(*items)
      invalid = items.reject { |item| node?(item) }
      unless invalid.empty?
        raise ArgumentError, "Emacs Lisp lists may contain only Elisp nodes"
      end

      List.new(items: items.freeze)
    end

    def node?(value)
      value.is_a?(Symbol) || value.is_a?(String) || value.is_a?(List)
    end
  end
end
