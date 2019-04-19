require 'puppet-deptool/parser'
require 'puppet-deptool/scanner'
require 'puppet-deptool/module'
require 'puppet-deptool/control-repo'

module PuppetDeptool
  def self.parser(options)
    @parser = Parser.new(options)
  end
  def self.scanner(options)
    @scanner = Scanner.new(options)
  end
  def self.module(options)
    @module = Module.new(options)
  end
  def self.control_repo(options)
    @control_repo = ControlRepo.new(options)
  end
end
