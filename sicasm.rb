# 0-7   label
# 8     blank (used as flag in sic/xe)
# 9-14  mnenomic
# 15-16 blank
# 17-35 operand
# 36-   comment

# instruction format
# +----8---+1+-------15------+
# +--------+-+---------------+
# | OPCODE |x|     ADDRESS   |
# +--------+-+---------------+

# Instruction & Directive:
#   only store and extract flags
# Assembler
#   determine which container & determine how to form object code
#

# pass1
# statement listing
# store symbols into symtab with value point to statement
#
# pass2
# iterate over statements
#
require 'json'

module SICXE
    DIRECTIVES = %w{ START END RESW RESB BYTE WORD }
    ERRORS = JSON.parse(File.read('messages.json'))
    OPCODE = JSON.parse(File.read('opcodes.json'))
    REGISTERS = {
      "A"  => 0,
      "X"  => 1,
      "L"  => 2,
      "B"  => 3,
      "S"  => 4,
      "T"  => 5,
      "F"  => 6,
      "PC" => 8,
      "SW" => 9
    }

  def self.errno id
    ERRORS[id]
  end

  def self.opcode op
    OPCODE[op.upcase]
  end

  def self.register reg
    REGISTERS[reg.upcase]
  end

  def self.directive dir
    DIRECTIVES.include?(dir.upcase) ? dir : nil
  end

  class Statement
    attr_reader :lineno, :operator, :operands, :comment
    def initialize lineno:, operator:, operands:, comment:
      @lineno, @operator, @operands, @comment = lineno, operator, operands, comment
    end

    def size
      raise "should implemented by subclass"
    end

    def to_s
      "%d: (%d) %s %s ;%s" % [ @lineno, size, @operator, @operands, comment ]
    end

    alias inspect to_s
  end

  class Instruction < Statement
    attr_reader :size, :flags
    def initialize **args
      super(**args)
      @flags = []
      parse_format
      parse_arg
    end

    def parse_format
      op = SICXE.opcode(@operator.delete('+'))
      if @operator[0] == '+'
        if op["formats"].include? 4
          format = 4
          @flags << :extend
        else
          raise "invalid extend flag for operator \"#{ @operator }\""
        end
      elsif op["formats"].length > 1
        format ||= 3
      else
        format = op["formats"][0]
      end
      @size = format
    end

    def parse_arg
      return unless @operands
      args = @operands.split(/ *, */)
      if args.include? 'X'
        @flags << :index
        args.delete 'X'
      end
    end
  end

  class Directive < Statement
    attr_reader :size
    def initialize **args
      super(**args)
      prepare
    end

    def prepare
      case @operator.upcase
      when 'START'
        @size = @operands.to_i 16
      when 'RESW'
        @size = @operands.to_i * 3
      when 'RESB'
        @size = @operands.to_i
      when 'BYTE'
        @size = 1
      when 'WORD'
        @size = 3
      when 'END'
        @size = 0
      end
    end
  end

  class Comment < Statement
    def initialize lineno:, content:
      @lineno, @content = lineno, content
    end

    def to_s
      "%d: %s" % [ @lineno, @content ]
    end

    alias inspect to_s
  end

  class Assembler
    def initialize fname
      @fname = fname
      @file = File.open(fname, "rb")

      @progname = ""

      @list = []
      @symtab = {}
      @memmap = {}

      @linecnt = 0
      @memcnt = 0
    end

    def pass1
      @file.each_line do |line|
        @linecnt += 1
        next if line.strip.empty? || line =~ /^\s*$/  # empty line still count as a line
        @list << parse(line)
      end
      puts @list
      pp @symtab
    end

    def parse line
      line = line.strip.upcase
      return Comment.new(lineno: @linecnt, content: line) if line =~ /^\s*[.;]/
      # include extend flag in operator, addressing mode in operands

      label = nil
      tokens = line.split(/(?<!,) +(?!,)/)
      label = tokens.shift unless SICXE.opcode(tokens.first.delete('+')) or SICXE.directive(tokens.first)

      operator = tokens.shift

      if SICXE.opcode operator.delete('+')
        return instruction tokens, operator: operator, label: label
      elsif SICXE.directive operator
        return directive tokens, operator: operator, label: label
      else
        raise "Unknown operator \"#{ operator }\""
      end
    end

    def directive rest, label:, operator:
      operands = rest.shift
      comment = rest.join ' '
      d = Directive.new lineno: @linecnt, operator: operator, operands: operands, comment: comment
      @symtab[label.upcase] = @memcnt if label
      @memcnt += d.size
      d
    end

    def instruction rest, label:, operator:
      op = SICXE.opcode operator.delete('+')
      operands = nil
      operands = rest.shift if op["argcnt"] > 0
      comment = rest.join(' ')
      i = Instruction.new lineno: @linecnt, operator: operator, operands: operands, comment: comment
      @symtab[label.upcase] = @memcnt if label
      @memcnt += i.size
      i
    end
  end
end

if File.expand_path(__FILE__) == File.expand_path($0)
  SICXE::Assembler.new(ARGV[0]).pass1
end