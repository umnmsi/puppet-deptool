require 'puppet-deptool/parser'

module PuppetDeptool
  def self.parser(options)
    @parser = Parser.new(options)
  end
end
