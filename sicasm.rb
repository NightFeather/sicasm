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
    REGISTERS[reg.upcase] if reg
  end

  def self.directive dir
    DIRECTIVES.include?(dir.upcase) ? dir : nil
  end

  class Error < Exception
    attr_reader :lineno, :errno
    def initialize lineno, errno, message = ""
      super(message)
      @lineno, @errno = lineno, errno
    end
  end

  class Statement
    attr_reader :lineno, :offset, :label, :operator, :arg, :operands, :comment
    def initialize lineno:, offset:, label:, operator:, operands:, comment:
      @lineno, @offset, @label, @operator, @operands, @comment = lineno, offset, label, operator, operands, comment
      @arg = @operands
    end

    def size
      raise "should implemented by subclass"
    end

    def to_s
      #"%d: (%d) %s %s ;%s" % [ @lineno, size, @operator, @operands, comment ]
      "%04X %8s %-9s %-8s %-18s %s" % [
        @offset,
        assemble,
        @label,
        @operator,
        @arg,
        @comment
      ]
    end

    def assemble
      raise "should be implemented by child"
    end

    alias inspect to_s
  end

  class Instruction < Statement
    attr_reader :size, :flags, :valid, :error, :opdata
    def initialize **args
      super(**args)
      @flags = []
      @valid = false
      @opdata = SICXE.opcode(@operator.delete('+'))
      parse_format
      parse_arg
      validate
    end

    def parse_format
      @flags << :xe if opdata["sicxe"]
      if @operator[0] == '+'
        if opdata["formats"].include? 4
          format = 4
          @flags << :extend
          #@operator = @operator.delete '+'
        else
          raise "invalid extend flag for operator \"#{ @operator }\""
        end
      elsif opdata["formats"].length > 1
        format ||= 3
      else
        format = opdata["formats"][0]
      end
      @size = format
    end

    def parse_arg
      return unless @operands
      args = @operands.split(/ *, */)
      if args.include? 'X'
        @flags << :idx
        args.delete 'X'
      end
      @operands = args.map { |arg| arg_type arg }
    end

    def arg_type arg
      if arg =~ /^#/
        @flags << :immediate
        arg = arg.delete '#'
      elsif arg =~ /^@/
        @flags << :indirect
        arg = arg.delete '@'
      end

      if arg =~ /^\d+$/
        { type: :integer, value: arg.to_i }
      elsif arg =~ /^\d[0-9a-f]+h$/i
        { type: :integer, value: arg.to_i(16) }
      elsif arg =~ /^0x[0-9a-f]+$/
        { type: :integer, value: arg.to_i(16) }
      elsif REGISTERS.include? arg
        { type: :register, value: arg }
      else
        { type: :symbol, value: arg }
      end
    end

    def validate
      if opdata["args"].empty? and (@operands.nil? or @operands.empty?)
        @valid = true
      elsif @operands and opdata["args"].length == @operands.length
        @valid = opdata["args"].zip(@operands.map { |o| o[:type] }).map do |arg, opt|
          arg and opt and arg == "general" or arg == opt.to_s
        end.reduce(&:&)
        @error = "mismatched operand type, expected #{opdata["args"]} <-> got #{@operands}" unless @valid
      else
        @valid = false
        @error = "mismatched number of operand, expected #{opdata["args"].count} got #{@operands.length}" unless @valid
      end
    end

    def assemble v=nil
      output =  []
      output[0] = opdata["code"]

      if @flags.include? :immediate
        output[0] |= 1
      elsif @flags.include? :indirect
        output[0] |= 2
      elsif not ((@flags - [:xe, :idx]).empty?)
        output[0] |= 3
      end

      output[0] = "%02X" % output[0]
      case size
      when 2
        output[1] = (SICXE.register(@operands[0][:value]) || 0) << 4
        output[1] |= SICXE.register(@operands[1][:value]) || 0 if @operands[1]
        output[1] = "%02X" % output[1]
      when 3
        value = (@operands and @operands[0] and @operands[0][:type] != :symbol) ? @operands[0][:value] : 0
        value |= 0x1000 if @flags.include? :extend
        value |= 0x2000 if @flags.include? :pc
        value |= 0x4000 if @flags.include? :base
        value |= 0x8000 if @flags.include? :idx
        output[1] = "%04X" % (value)
      when 4
        value = (@operands and @operands[0] and @operands[0][:type] != :symbol) ? @operands[0][:value] : 0
        value |= 0x100000 if @flags.include? :extend
        value |= 0x200000 if @flags.include? :pc
        value |= 0x400000 if @flags.include? :base
        value |= 0x800000 if @flags.include? :idx
        output[1] = "%06X" % (value)

      end
      output.join
    end

    alias inspect to_s

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
        raise Error.new(@lineno, 2) if @label and @label.empty?
        raise Error.new(@lineno, 3) if @operands and @operands.empty?
        raise Error.new(@lineno, 4) if @operands !~ /^[a-f0-9]+$/
        @offset = @operands.to_i 16
        @size = @offset
        @operands = { type: :integer, value: @operands.to_i(16) }
      when 'RESW'
        @size = @operands.to_i * 3
        @operands = parse_literal @operands
      when 'RESB'
        @size = @operands.to_i
        @operands = parse_literal @operands
      when 'BYTE'
        @size = 1
        @operands = parse_literal @operands
      when 'WORD'
        @size = 3
        @operands = parse_literal @operands
      when 'END'
        @size = 0
        @operands = parse_literal @operands
      end
      @operands = [@operands]
    end

    def parse_literal lit
      type, data = [ nil,nil]
      case lit
      when /^\d+$/
        type = :integer
        data = lit.to_i
      when /^[0-9a-f]h$/i
        type = :integer
        data = lit.to_i 16
      when /^0x[0-9A-Fa-f]$/
        type = :integer
        data = lit.to_i 16
      when /^C'(.+)'$/i
        type = :char
        data = $~[1].bytes
        @size = data.length
      when /^X'([0-9a-z]+)'$/i
        type = :hex
        data = $~[1].to_i(16)
      else
        type = :symbol
        data = lit
      end
      { type: type, value: data }
    end

    def assemble v=nil
      return "" unless v
      return "" unless %w{ WORD BYTE }.include? @operator
      @operands.map do |op|
        case op[:type]
        when :integer
          if @operator == "START" or @operator == "RESB" or @operator == "RESW"
            "00..00"
          else
            "%0*X" % [ size*2, op[:value]]
          end
        when :char
          op[:value].map { |i| "%02X" % i }.join
        when :hex
          "%0*X" % [ size*2, op[:value] ]
        when :symbol
          "00"
        end
      end.join
    end

  end

  class Comment < Statement
    def initialize lineno:, content:
      @lineno, @content = lineno, content
    end

    def to_s
      @content
    end

    def assemble v=nil
      ""
    end

    alias inspect to_s
  end

  class Assembler
    attr_reader :list, :has_error
    def initialize fname
      @fname = fname
      @file = File.open(fname, "rb")

      @progname = ""

      @list = []
      @symtab = {}
      @memmap = {}

      @linecnt = 0
      @membase = 0
      @memcnt = 0

      @has_error = false
    end

    def pass1
      puts "pass1 start."
      @file.each_line do |line|
        @linecnt += 1
        next if line.strip.empty? || line =~ /^\s*$/  # empty line still count as a line
        @list << parse(line)
        rescue SICXE::Error => e
          @has_error = true
          puts "error at line ##{e.lineno}: #{SICXE.errno(e.errno)["message"]}"
      end
      puts "pass1 end."
    end

    def pass2
      if @has_error
        puts "pass2: errors occurred in previous phase, won't continue"
        return
      end
      puts "pass2 start."
      @list.map do |line|
        if line.operands
          line.operands.map! do |op|
            if op.is_a? Hash and op[:type] == :symbol
              { type: :integer, value: @symtab[op[:value]] }
            else
              op
            end
          end
        else
          line
        end
      end.compact
      puts "pass2 end."
    end

    def assemble target
      if @has_error
        puts "objgen: errors occurred in previous phase, won't continue"
        return
      end
      puts "writing objectcode..."
      i = -1
      buffer = ""
      File.open target, "w" do |f|
        f.puts "H%-6s %06X%06X" % [ @progname, @symtab[@progname], @memcnt - @symtab[@progname] ]
        @list.each do |st|
          next if st.is_a? Comment
          s = st.assemble true
          if i + s.length > 60 || (i > 0 && (st.operator == 'RESW' || st.operator == 'RESB'))
            f.puts "%02X%s" % [ buffer.length/2, buffer ]
            i = -1
            buffer.clear
          end
          if i < 0 and not ( st.operator == 'RESW' or st.operator == 'RESB' )
              f.print "T%06X" % st.offset
              i = 0
          end

          i += s.length
          buffer += s
        end
        f.puts "%02X%s" % [ buffer.length/2, buffer ]
        f.puts "E%06X" % [ @symtab[@progname] ]
      end
    end

    private
    def parse line
      line = line.upcase
      return Comment.new(lineno: @linecnt, content: line) if line =~ /^\s*[.;]/
      # include extend flag in operator, addressing mode in operands

      label = nil
      # tokens = line.split(/(?<!,) (?!,|\s)/).map(&:strip)
      # well, seems we still need to parse according to column size
      # otherwise, it's impossible to identify most of the syntax errors
      tokens = line[0..6], line[8..13], line[15..34], line[35..-1]
      tokens.map! { |i| i and i.strip }

      label = tokens.shift
      operator = tokens.shift

      raise Error.new(@linecnt, 0) if !label.empty? and label !~ /^[a-z_][a-z0-9_]*$/i
      raise Error.new(@linecnt, 1) unless operator =~ /^\+?[a-z_]+$/i

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
      d = Directive.new lineno: @linecnt, offset: @memcnt, label: label, operator: operator, operands: operands, comment: comment
      if operator == 'START'
        @progname = label
        @memcnt += d.size
        @symtab[label.upcase] = @memcnt
      else
        @symtab[label.upcase] = @memcnt unless label.empty?
        @memcnt += d.size
      end
      d
    end

    def instruction rest, label:, operator:
      operands = nil
      operands = rest.shift
      comment = rest.join(' ')
      i = Instruction.new lineno: @linecnt, offset: @memcnt,
                          label: label, operator: operator,
                          operands: operands, comment: comment
      unless i.valid
        puts "invalid instruction :"
        puts "  " + i.to_s
        puts "  " + i.error
      end
      @symtab[label.upcase] = @memcnt unless label.empty?
      @memcnt += i.size
      i
    end
  end
end

if File.expand_path(__FILE__) == File.expand_path($0)
  asm = SICXE::Assembler.new(ARGV[0])
  asm.pass1
  asm.pass2
  File.open ARGV[0] + ".lst", "w+" do |f|
    f.write "SICASM.RB v0.0.87\n\n"
    asm.list.map do |st|
      f.puts st.to_s
    end
  end
  asm.assemble ARGV[0] + ".obj"
end
