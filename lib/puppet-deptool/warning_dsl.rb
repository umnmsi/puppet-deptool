require 'puppet-deptool/base'

# Class for parsing known warnings file
module PuppetDeptool
  class WarningsDSL < Base

    def initialize(known_warnings)
      super
      @known_warnings = known_warnings
    end

    WARNING_TYPES.each do |type, attrs|
      attrs_array = "[#{attrs.map { |attr| ":#{attr}" }.join(', ')}]"
      class_eval <<-METHOD, __FILE__, __LINE__ + 1
      def #{type}(**kwargs)
        kwargs.keys.each do |arg|
          raise ArgumentError.new("Invalid #{type} option \#{arg}") unless #{attrs_array}.include? arg
        end
        missing_args = []
        #{attrs_array}.each do |arg|
          missing_args << arg.to_s unless kwargs.include? arg
        end
        unless missing_args.empty?
          source = caller_locations(1).first
          line = IO.readlines(source.absolute_path)[source.lineno - 1, 1][0].gsub(\%r{\\n},'')
          raise ArgumentError.new("#{type} missing argument(s) \#{missing_args.join(', ')}: \#{source.path}:\#{source.lineno}: \#{line}")
        end
        @known_warnings[:#{type}] << { #{attrs.map { |attr| "#{attr}: kwargs[:#{attr}]" }.join(', ')} }
      end
      METHOD
    end
  end
end
