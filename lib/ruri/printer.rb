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
        return ["#{padding}#{render_inline(node)}"] unless node.is_a?(List)
        return ["#{padding}()"] if node.items.empty?

        if node.items.all? { |item| inline?(item) }
          return ["#{padding}(#{node.items.map { |item| render_inline(item) }.join(" ")})"]
        end

        leading_count = node.items.index { |item| !inline?(item) } || node.items.length
        leading = node.items.take(leading_count)
        nested = node.items.drop(leading_count)
        lines = ["#{padding}(#{leading.map { |item| render_inline(item) }.join(" ")}"]
        nested.each { |item| lines.concat(render(item, indent + 1)) }
        lines[-1] += ")"
        lines
      end

      def inline?(node)
        node.is_a?(Symbol) || node.is_a?(String) || (node.is_a?(List) && node.items.empty?)
      end

      def render_inline(node)
        case node
        when Symbol
          node.name
        when String
          self.class.quote(node.value)
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
