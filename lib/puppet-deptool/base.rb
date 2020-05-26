require 'puppet-deptool/consts'
require 'puppet-deptool/git'
require 'puppet-deptool/logger'
require 'puppet-deptool/util'

module PuppetDeptool
  class Options
    def initialize(options)
      @options = options
    end

    def [](option = nil)
      return @options if option.nil?
      raise "Unknown option #{option}" unless @options.key? option
      @options[option]
    end

    def []=(option, value)
      raise "Unknown option #{option}" unless @options.key? option
      @options[option] = value
    end
  end
  class Base
    include Consts
    extend Consts
    include Logger
    extend Logger

    attr_accessor :options

    def initialize(opts)
      raise 'options must be a hash' unless opts.is_a? Hash
      @options = Options.new(opts)
      Logger.debug = options[:debug] unless opts[:debug].nil?
      Logger.verbose = options[:verbose] unless opts[:verbose].nil?
      Logger.quiet = options[:quiet] unless opts[:quiet].nil?
    end
  end
end
