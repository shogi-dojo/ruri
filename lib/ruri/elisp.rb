# frozen_string_literal: true

module Ruri
  # A small, safe representation of Emacs Lisp data. Language-specific
  # lowering produces these nodes; Printer is solely responsible for turning
  # them into source text.
  module Elisp
    SYMBOL_RE = /\A[a-zA-Z0-9+*\/<>=!?$%_&~^:.@-]+\z/.freeze

    Symbol = Data.define(:name)
    String = Data.define(:value)
    Integer = Data.define(:value)
    Float = Data.define(:value)
    List = Data.define(:items)
    Vector = Data.define(:items)
    Quote = Data.define(:value)

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

    def integer(value)
      raise ArgumentError, "expected an Integer" unless value.is_a?(::Integer)

      Integer.new(value: value)
    end

    def float(value)
      unless value.is_a?(::Float) && value.finite?
        raise ArgumentError, "expected a finite Float"
      end

      Float.new(value: value)
    end

    def list(*items)
      validate_items!(items, "lists")
      List.new(items: items.freeze)
    end

    def vector(*items)
      validate_items!(items, "vectors")
      Vector.new(items: items.freeze)
    end

    def quote(value)
      raise ArgumentError, "quoted values must be Elisp nodes" unless node?(value)

      Quote.new(value: value)
    end

    def node?(value)
      [Symbol, String, Integer, Float, List, Vector, Quote].any? { |type| value.is_a?(type) }
    end

    def validate_items!(items, collection)
      return if items.all? { |item| node?(item) }

      raise ArgumentError, "Emacs Lisp #{collection} may contain only Elisp nodes"
    end
    private_class_method :validate_items!
  end
end
