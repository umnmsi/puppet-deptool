require 'generate_puppetfile'
require 'puppet-deptool/base'
require 'puppet-deptool/environment'
require 'r10k/action/puppetfile/install'

module PuppetDeptool
  class ControlRepo < Base
    include Git

    attr_accessor :path, :prefix, :puppetfile_path

    def initialize(opts)
      super
      raise "Required parameter :path missing" if opts[:path].nil?
      @path = options[:path]
      raise "path #{path} does not exist" unless File.directory?(path)
      @modules = {}
      @prefix = options[:prefix] || File.basename(path).sub('_control', '')
    end

    def to_s
      "#{File.basename(path)} (#{path})"
    end

    def environment(name)
      branch_to_environment(name.sub(/^#{prefix}_/, ''))
    end

    def current_environment
      branch_to_environment(current_branch(path: path))
    end

    def checkout_environment(name, clean: false)
      checkout(environment(name).branch, path: path, clean: clean)
    end

    def deploy_environment(name, clean: false)
      environment(name).deploy(clean: clean)
    end

    def environments(filter: [], remote: 'origin')
      info "Searching for branches#{filter.empty? ? '' : " matching #{filter}"}"
      envs = []
      remote_branches(path: path, remote: remote).each do |ref|
        next if ref.eql?("#{remote}/HEAD")
        next unless filter.empty? || filter.any? { |f| ref =~ %r{\b#{f}\b} }
        info "Processing branch #{ref}"
        envs << Environment.new(control_repo: self, branch: ref_to_branch(ref), skip_check: true)
      end
      envs
    end

    def environments_with_module(mod, filter: [], remote: 'origin')
      info "Searching for branches with module #{mod.name}#{filter.empty? ? '' : " matching #{filter}"}"
      environments(filter: filter, remote: remote).select do |env|
        mods = env.modules
        info "Found modules #{mods.map { |m| m[:name] }}"
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
