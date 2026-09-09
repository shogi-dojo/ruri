# frozen_string_literal: true

require "tempfile"

module Ruri
  # Command line interface:
  #   ruri compile INPUT --output OUTPUT
  #
  # Success exits 0 and writes the .el file. Failure exits nonzero and
  # prints "path:line:column: message" diagnostics to stderr, leaving any
  # existing output untouched.
  class CLI
    USAGE = "usage: ruri compile INPUT --output OUTPUT"

    EXIT_OK = 0
    EXIT_COMPILE_ERROR = 1
    EXIT_USAGE = 2

    class << self
      def run(argv, stdout: $stdout, stderr: $stderr)
        new(argv, stdout: stdout, stderr: stderr).run
      end
    end

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv
      @stdout = stdout
      @stderr = stderr
    end

    def run
      unless (args = parse_args)
        @stderr.puts USAGE
        return EXIT_USAGE
      end

      source = File.read(args[:input], encoding: "UTF-8")
      commands = Parser.parse(source, path: args[:input])
      output = Emitter.emit(commands, source_path: args[:input])
      atomic_write(output, to: args[:output])
      EXIT_OK
    rescue Ruri::CompileError => e
      @stderr.puts e.diagnostics.map(&:to_s).join("\n")
      EXIT_COMPILE_ERROR
    rescue SystemCallError => e
      @stderr.puts "#{args[:input]}: #{e.message}"
      EXIT_COMPILE_ERROR
    end

    private

    def parse_args
      return nil unless @argv.length == 4
      return nil unless @argv[0] == "compile"
      return nil unless @argv[2] == "--output"
      return nil if @argv[1].empty? || @argv[3].empty?

      { input: @argv[1], output: @argv[3] }
    end

    # Parse and emit happen before the output is touched; the temp file is
    # renamed over the target in the same directory, so a failure anywhere
    # preserves any previously generated output.
    def atomic_write(content, to:)
      dir = File.dirname(to)
      Tempfile.create(["ruri-", ".el"], dir) do |tmp|
        tmp.write(content)
        tmp.flush
        File.rename(tmp.path, to)
      end
    end
  end
end
