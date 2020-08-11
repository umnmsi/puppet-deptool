require 'puppet-deptool/base'
require 'puppet-deptool/environment'
require 'r10k/action/puppetfile/install'

module PuppetDeptool
  class ControlRepo < Base
    include Git

    attr_accessor :path, :prefix

    def initialize(opts)
      super
      raise "Required parameter :path missing" if opts[:path].nil?
      @path = options[:path]
      raise "path #{path} does not exist" unless File.directory?(path)
      @modules = {}
      @prefix = opts[:prefix] || File.basename(path).sub('_control', '')
    end

    def to_s
      "#{File.basename(path)} (#{path})"
    end

    def environment(name)
      branch_to_environment(name.sub(/^#{prefix}_/, ''))
    end

    def current_environment
      branch = current_branch(path: path)
      raise 'Failed to determine environment name: Control repo branch resolved to HEAD' if branch.eql?('HEAD')
      @current_environment ||= branch_to_environment(branch)
    end

    def checkout_environment(name, opts = {})
      @current_environment = environment(name)
      checkout(@current_environment.branch, { path: path }.merge(opts))
    end

    def deploy_environment(name, opts = {})
      checkout_environment(name, opts)
      environment(name).deploy(force: opts[:force])
    end

    def environments(filter: [], remote: 'origin')
      debug "Searching for branches#{filter.empty? ? '' : " matching #{filter}"}"
      envs = []
      remote_branches(path: path, remote: remote).each do |ref|
        next if ref.eql?("#{remote}/HEAD")
        next unless filter.empty? || filter.any? { |f| ref =~ %r{\b#{f}\b} }
        debug "Processing branch #{ref}"
        envs << Environment.new(control_repo: self, branch: ref_to_branch(ref), skip_check: true)
      end
      envs
    end

    def environments_with_module(mod, filter: [], remote: 'origin')
      debug "Searching for branches with module #{mod.name}#{filter.empty? ? '' : " matching #{filter}"}"
      environments(filter: filter, remote: remote).select do |env|
        mods = env.modules
        debug "Found modules #{mods.map { |m| m[:name] }}"
        mods.each do |m|
          debug "Comparing #{m} to #{mod}"
          next unless m[:name].eql?(mod.name)
          if m[:author].nil?
            warn "WARNING: Unable to compare module author for #{m[:name]} in #{env.name}. Update Puppetfile declaration to use '<author>-<name>' syntax."
          elsif ! m[:author].eql?(mod.author)
            next
          end
          true
        end
      end
    end

    def branch_to_environment(branch)
      Environment.new(control_repo: self, branch: branch)
    end
  end
end
