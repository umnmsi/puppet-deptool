require 'puppet-deptool/consts'
require 'puppet-deptool/logger'
require 'puppet-deptool/git'

module PuppetDeptool
  class Util
    class << self
      include Consts
      include Git
      include Logger

      @@known_warnings = Hash[WARNING_TYPES.map { |type, _| [type, []] }]
      @@found_warnings = Hash[WARNING_TYPES.map { |type, _| [type, []] }]

      def known_warnings
        @@known_warnings
      end

      def found_warnings
        @@found_warnings
      end

      def warning_known?(warning_type, *args)
        raise "Unknown warning type #{warning_type}" unless @@known_warnings.key? warning_type
        warning = Hash.new
        WARNING_TYPES[warning_type].each_with_index do |attr, index|
          warning[attr] = args[index]
        end
        @@found_warnings[warning_type] << warning
        return true if @@known_warnings[warning_type].any? { |known| warning == known }
      end

      def github_control_repos
        @github_control_repos ||= Github.control_repositories
      end

      def r10k_control_repos
        return @r10k_control_repos unless @r10k_control_repos.nil?
        @r10k_control_repos = r10k_config['sources'].select do |name, source|
          debug "Checking r10k repo #{name} / #{source}"
          if source['basedir'].eql?('/etc/puppetlabs/code/environments') && source['prefix'] === true
            debug "Found r10k control repo #{name}"
            true
          end
        end
        debug "Found r10k control repositories #{@r10k_control_repos}"
        @r10k_control_repos
      end

      def r10k_cache_dir
        @r10k_cache_dir ||= clone_or_update({ 'name' => 'r10k_config', 'ssh_url' => R10K_CONFIG_REPO })
      end

      def r10k_config_file
        @r10k_config_file ||= File.join(r10k_cache_dir, 'r10k.yaml')
      end

      def r10k_config
        return @r10k_config unless @r10k_config.nil?
        unless File.file? r10k_config_file
          raise "Failed to find r10k config #{r10k_config_file}"
          exit 1
        end
        @r10k_config = YAML.load(File.read(r10k_config_file))
      end

      def envlink_cache_dir
        r10k_cache_dir
      end

      def envlink_config_file
        @envlink_config_file ||= File.join(envlink_cache_dir, 'envlink.yaml')
      end

      def envlink_config
        return @envlink_config unless @envlink_config.nil?
        unless File.file? envlink_config_file
          raise "Failed to find envlink config #{envlink_config_file}"
          exit 1
        end
        @envlink_config = YAML.load(File.read(envlink_config_file))
      end

      def environment_to_control_repo(environment)
        r10k_control_repos.each do |control_repo, info|
          debug "Checking #{control_repo} against #{environment}"
          if environment.match?(%r{^#{control_repo}_})
            info "Mapped environment #{environment} to #{control_repo}_control. Cloning repo..."
            unless info['remote'].match?(%r{#{control_repo}_control})
              warn "Control repo URL #{info['remote']} doesn't match expected pattern '<name>_control'"
              return nil
            end
            path = clone_or_update({ 'name' => "#{control_repo}_control", 'ssh_url' => info['remote'] })
            repo = PuppetDeptool.control_repo(path: path, prefix: control_repo)
            repo.checkout_environment(environment)
            return repo
          end
        end
        nil
      end

      def envlink_branch(link:, path:, environment:)
        fallback_branch = nil
        remote_branches(path: path).each do |branch|
          debug "Comparing #{branch} to #{environment.name}"
          return branch if branch.match?(%r{/#{environment.name}$})
          return branch if link['map'].key?(environment.name) && branch.match?(%r{/#{link['map'][environment.name]}$})
          fallback_branch = branch if !link['fallback_branch'].nil? && branch.match?(%r{/#{link['fallback_branch']}$})
        end
        return fallback_branch unless fallback_branch.nil?
        raise "No matching branch found for link #{link['link_name']} and no fallback branch defined" if link['fallback_branch'].nil?
        raise "No matching branch found for link #{link['link_name']} and fallback branch #{link['fallback_branch']} doesn't exist"
      end

      def is_control_repo?(path)
        File.exist?(File.join(path, 'Puppetfile'))
      end
    end
  end
end
