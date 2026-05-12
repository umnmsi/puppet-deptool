# frozen_string_literal: true

require 'puppet_deptool/consts'
require 'puppet_deptool/git'
require 'puppet_deptool/logger'
require 'puppet_deptool/util'

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
      raise 'options must be a hash' unless opts.nil? || opts.is_a?(Hash)

      @options = Options.new(opts)
      Logger.level = options[:verbose] unless opts[:verbose].nil?
    end
  end
end
