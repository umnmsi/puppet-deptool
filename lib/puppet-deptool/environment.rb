require 'puppet-deptool/base'
require 'r10k/action/puppetfile/install'

module PuppetDeptool
  class Environment < Base
    include Git

    attr_accessor :control_repo, :branch

    def initialize(opts)
      super
      raise "Required parameter :control_repo missing" if opts[:control_repo].nil?
      @control_repo = options[:control_repo]
      raise "Required parameter :branch missing" if opts[:branch].nil?
      @branch = options[:branch]
      unless options[:skip_check]
        raise "Invalid branch #{branch}" unless control_repo.branch_exists?(branch, path: path)
      end
      fetch_puppetfile
    end

    def prefix
      control_repo.prefix
    end

    def path
      control_repo.path
    end

    def name
      "#{control_repo.prefix}_#{branch}"
    end

    def fetch_puppetfile
      return @puppetfile_content unless @puppetfile_content.nil?
      @puppetfile_path = File.join(path, 'Puppetfile')
      @puppetfile_content = git ['show', "#{branch}:Puppetfile"], path: path
      debug "Found Puppetfile content:\n#{@puppetfile_content}"
      @puppetfile_content
    rescue GitError
      raise "Control repo #{path} branch #{branch} does not contain a Puppetfile"
    end

    def deploy(clean: false, force: false)
      checkout(branch, path: path, clean: clean)
      R10K::Logging.level = if Logger.debug
                              'DEBUG'
                            elsif Logger.verbose
                              'INFO'
                            else
                              'WARN'
                            end
      R10K::Action::Puppetfile::Install.new({root: path, force: force}, nil).call
      prepare_envlink_targets
    end

    def modules
      return @modules unless @modules.nil?
      puppetfile = Puppetfile.new
      puppetfile.instance_eval(@puppetfile_content, @puppetfile_path)
      @modules = puppetfile.modules
    end

    def module_version(name)
      modules.each do |mod|
        return mod[:version] if mod[:name].eql?(name) && !mod[:version].nil?
      end
      nil
    end

    def prepare_envlink_targets
      unless source = Util.r10k_control_repos[prefix]
        warn "WARNING: Failed to find r10k config for control repo #{prefix}"
      end
      unless links = Util.envlink_config['links'][prefix]
        warn "WARNING: Failed to find envlink config for control repo #{prefix}"
        links = []
      end
      info "Found source #{source}, links #{links}"
      links.each do |link|
        unless link_source = Util.r10k_config['sources'][link['r10k_source']]
          warn "WARNING: Failed to find r10k config for envlink link #{link['link_name']}"
          next
        end
        info "Processing link #{link['link_name']}"
        link_path = clone_or_update({ 'name' => link['link_name'], 'ssh_url' => link_source['remote'] })
        branch = Util.envlink_branch(link: link, path: link_path, environment: self)
        checkout(branch, path: link_path, clean: true)
        info "Creating symlink from #{link_path} to #{File.join(path, link['link_name'])}"
        FileUtils.symlink(link_path, path, force: true)
      end
    end
  end

  class Puppetfile
    attr_accessor :modules

    def initialize
      @modules = []
    end

    def mod(name, args = nil)
      version = if args.is_a? Hash
                  nil
                else
                  args
                end
      %r{\A((?<author>[^-/]+)[-/])?(?<name>.*)\Z} =~ name
      @modules << { name: name, author: author, version: version, args: args }
    end

    def to_s
      @modules.map {|mod| "#{mod[:name]} #{mod[:version]}" }.join(' ')
    end

    def method_missing(method, *args)
    end
  end
end
