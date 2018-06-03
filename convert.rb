require 'json'

lst = %w{
  LDA 
  LDX 
  LDL 
  STA 
  STX 
  STL 
  ADD 
  SUB 
  MUL 
  DIV 
  COMP
  TIX 
  JEQ 
  JGT 
  JLT 
  J 
  AND 
  OR
  JSUB
  RSUB
  LDCH
  STCH
}

puts \
  ARGF.each_line
    .map(&:split)
    .map { |op,arg,form,code|
      if arg =~ /m|r|n/
        arg = arg.split(",").map do |a|
          case a
          when /r\d/
            :register
          when 'm'
            :general
          when 'n'
            :numeric
          end
        end
      else
        arg, form, code = [], arg, form
      end
      [op,arg,form,code]
    }.map { |op,arg, form, code|
      [
        op,
        {
          args: arg,
          formats: form.split(?/).map(&:to_i),
          code: code.to_i(16),
          sicxe: lst.include?(op)
        }
      ]
    }.to_h.to_json
