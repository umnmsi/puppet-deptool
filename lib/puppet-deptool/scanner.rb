require 'puppet-deptool/logger'
require 'puppet-deptool/control-repo'

module PuppetDeptool
  class Scanner
    include Logger

    def initialize(options)
      @options = options
      Logger.debug = options[:debug]
      Logger.verbose = options[:verbose]
      Logger.quiet = options[:quiet]

      if options(:control_repo).empty?
        if builtin_control_repos.empty?
          warn 'No control repo directory specified and no built-in repos configured'
          exit 1
        end
        @options[:control_repo] = builtin_control_repos
      end
    end

    def options(option)
      raise "Unknown option #{option}" unless @options.key? option
      @options[option]
    end

    def module_name
      @module_name ||= File.basename(options(:module)).sub(/^module-/, '')
    end

    def find_environments
      info "Finding matching environments"
      environments = control_repos.map do |control_repo|
        info "Processing control repo #{control_repo}"
        control_repo.environments_with_module(module_name)
      end.flatten
      info "Found matching environments #{environments}"
    end

    def builtin_control_repos
      []
    end

    def control_repos
      @control_repos ||= options(:control_repo).map { |control_repo| ControlRepo.new(control_repo) }
    end
  end
end
