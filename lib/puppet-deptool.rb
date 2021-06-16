require 'optparse'
require 'puppet-deptool/consts'
require 'puppet-deptool/control-repo'
require 'puppet-deptool/module'
require 'puppet-deptool/parser'
require 'puppet-deptool/scanner'

module PuppetDeptool
  include Consts

  def self.parser(options: {}, parse_args: false)
    options = Parser.parse_args(options) if parse_args
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
    opts.on('-v', '--verbose', 'Enable verbose output. Can be specified twice to increase verbosity.') do
      options[:verbose] += 1
    end
    opts.on('-t', '--silent', 'Disable all output.') do
      options[:verbose] = 0
    end
    opts.on('-q', '--quiet', 'Disable default output. Warnings still displayed.') do
      options[:verbose] = 1
    end
  end
end
