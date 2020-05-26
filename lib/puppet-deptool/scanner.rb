require 'puppet-deptool/base'
require 'puppet-deptool/control-repo'
require 'puppet-deptool/github'
require 'puppet-deptool/module'

module PuppetDeptool
  class Scanner < Base
    include Git

    def initialize(opts)
      opts = Scanner.default_options.merge(opts)
      super(opts)
      if options[:control_repo].empty?
        if builtin_control_repos.empty?
          warn 'No control repo directory specified and no built-in repos configured'
          exit 1
        end
        @options[:control_repo] = builtin_control_repos
      end
    end

    def mod
      @module ||= Module.new(path: options[:module])
    end

    def find_environments
      info "Finding matching environments"
      environments = control_repos.map do |control_repo|
        info "Processing control repo #{control_repo}"
        control_repo.environments_with_module(mod, branch_filter)
      end.flatten
      info "Found matching environments #{environments.map { |e| e[:name] }}"
      environments
    end

    def test_environments
      find_environments.each do |env|
        info "Checking environment #{env[:name]}"
        test_environment env
        break
      end
    end

    def test_environment(env)
      orig_path = Dir.pwd
      Dir.chdir(env[:path])
      checkout(env[:branch], path: env[:path], clean: true)
      env[:control_repo].prepare_envlink_targets(env)
      # Generate .fixtures.yml
      GeneratePuppetfile::Bin.new(['--Puppetfile', 'Puppetfile', '--fixtures-only']).run
      info `cat .fixtures.yml`
      Dir.chdir(orig_path)
    end

    def branch_filter
      if options[:branch_filter].empty?
        ['production', 'develop']
      else
        options[:branch_filter]
      end
    end

    def builtin_control_repos
      return @builtin_control_repos unless @builtin_control_repos.nil?
      extra_r10k_control_repos = Util.r10k_control_repos.keys - Util.github_control_repos.map { |r| r['environment_prefix'] }
      unless extra_r10k_control_repos.empty?
        warn "WARNING: Found r10k control repo(s) that didn't match github search: #{extra_r10k_control_repos}"
      end
      @builtin_control_repos = Util.github_control_repos.map do |repo|
        repo_path = clone_or_update(repo)
      end
    end

    def control_repos
      @control_repos ||= options[:control_repo].map { |control_repo| ControlRepo.new(path: control_repo) }
    end

    class << self
      def default_options
        GLOBAL_DEFAULTS.dup.merge({
          control_repo: [],
          module: File.expand_path(Dir.pwd),
          branch_filter: [],
        })
      end

      def parse_args
        options = default_options

        optparser = OptionParser.new do |opts|
          PuppetDeptool.global_parser_options(opts, options)
          opts.on('-c', '--control-repo PATH', 'Path to control repository. Can be specified multiple times. If unspecified, all known control repos will be cloned and checked.') do |control_repo|
            unless Dir.exist? control_repo
              warn "Control repo directory #{control_repo} does not exist"
              exit 1
            end
            options[:control_repo] << File.expand_path(control_repo)
          end
          opts.on('-m', '--module', 'Set path to module. Defaults to working directory.') do |mod|
            unless Dir.exist? mod
              warn "Module directory #{mod} does not exist"
              exit 1
            end
            options[:module] = File.expand_path(mod)
          end
          opts.on('-b', '--branch-filter FILTER', 'Control repo branch to check for matching module. Can be specified more than once. Defaults to [\'production\', \'develop\'].') do |filter|
            options[:branch_filter] << filter
          end
        end

        begin
          optparser.parse!
        rescue => e
          warn e
          puts optparser
          exit 1
        end

        unless ARGV.empty?
          warn "unknown arguments: #{ARGV.join(', ')}"
          puts optparser
          exit 1
        end

        options
      end
    end
  end
end
