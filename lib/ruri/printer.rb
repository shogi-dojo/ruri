# frozen_string_literal: true

module Ruri
  module Elisp
    # Deterministically serializes generic Elisp nodes. Lists keep their
    # leading atomic arguments on the opening line and indent nested forms by
    # two spaces, producing conventional output without knowing any form names.
    class Printer
      ESCAPES = {
        "\\" => "\\\\",
        "\"" => "\\\"",
        "\n" => "\\n",
        "\t" => "\\t",
        "\r" => "\\r",
        "\f" => "\\f",
        "\e" => "\\e"
      }.freeze

      class << self
        def print(node)
          new.print(node)
        end

        def quote(text)
          escaped = text.each_char.map do |character|
            ESCAPES[character] || control_escape(character)
          end.join
          "\"#{escaped}\""
        end

        private

        def control_escape(character)
          if character.ord < 32 || character.ord == 127
            format("\\%03o", character.ord)
          else
            character
          end
        end
      end

      def print(node)
        render(node, 0).join("\n")
      end

      private

      def render(node, indent)
        padding = "  " * indent
        return render_collection(node.items, indent, "(", ")") if node.is_a?(List)
        return ["#{padding}#{render_inline(node)}"] if node.is_a?(InlineList)
        return render_collection(node.items, indent, "[", "]") if node.is_a?(Vector)

        ["#{padding}#{render_inline(node)}"]
      end

      def render_collection(items, indent, opening, closing)
        padding = "  " * indent
        return ["#{padding}#{opening}#{closing}"] if items.empty?

        if items.all? { |item| inline?(item) }
          values = items.map { |item| render_inline(item) }.join(" ")
          return ["#{padding}#{opening}#{values}#{closing}"]
        end

        leading_count = items.index { |item| !inline?(item) } || items.length
        leading = items.take(leading_count)
        nested = items.drop(leading_count)
        lines = ["#{padding}#{opening}#{leading.map { |item| render_inline(item) }.join(" ")}"]
        nested.chunk { |item| inline?(item) }.each do |is_inline, chunk|
          if is_inline
            values = chunk.map { |item| render_inline(item) }.join(" ")
            lines << "#{"  " * (indent + 1)}#{values}"
          else
            chunk.each { |item| lines.concat(render(item, indent + 1)) }
          end
        end
        lines[-1] += closing
        lines
      end

      def inline?(node)
        case node
        when Symbol, String, Integer, Float
          true
        when Quote
          inline?(node.value)
        when InlineList
          true
        when Vector
          node.items.all? { |item| inline?(item) }
        when List
          node.items.empty?
        else
          false
        end
      end

      def render_inline(node)
        case node
        when Symbol
          node.name
        when String
          self.class.quote(node.value)
        when Integer, Float
          node.value.to_s
        when Quote
          "'#{render_inline(node.value)}"
        when InlineList
          "(#{node.items.map { |item| render_inline(item) }.join(" ")})"
        when Vector
          return "[#{node.items.map { |item| render_inline(item) }.join(" ")}]" if inline?(node)

          raise ArgumentError, "nested vector cannot be rendered inline"
        when List
          return "()" if node.items.empty?

          raise ArgumentError, "nested nonempty list cannot be rendered inline"
        else
          raise ArgumentError, "cannot print Emacs Lisp node: #{node.class}"
        end
      end
    end
  end
end
