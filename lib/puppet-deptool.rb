require 'optparse'
require 'puppet-deptool/consts'
require 'puppet-deptool/control-repo'
require 'puppet-deptool/module'
require 'puppet-deptool/parser'
require 'puppet-deptool/scanner'

module PuppetDeptool
  include Consts

  def self.parser(options: {}, parse_args: false)
    options.merge!(Parser.parse_args) if parse_args
    @parser = Parser.new(options)
  end

  def self.scanner(options: {}, parse_args: false)
    options.merge!(Scanner.parse_args) if parse_args
    @scanner = Scanner.new(options)
  end

  def self.module(options)
    @module = Module.new(options)
  end

  def self.control_repo(options)
    @control_repo = ControlRepo.new(options)
  end

  def self.global_parser_options(opts, options)
    opts.on('-v', '--verbose', 'Enable verbose output.') do
      options[:verbose] = true
    end
    opts.on('-d', '--debug', 'Enable debug output.') do
      options[:debug] = true
    end
    opts.on('-q', '--quiet', 'Disable warning output.') do
      options[:quiet] = true
    end
  end
end
