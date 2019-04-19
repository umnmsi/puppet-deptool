require 'puppet-deptool/logger'

module PuppetDeptool
  class ControlRepo
    include Logger

    attr_accessor :path, :puppetfile_path

    def initialize(options)
      @path = options[:path]
      @puppetfile_path = File.join(path, 'Puppetfile')
    end

    def to_s
      "#{File.basename(path)} (#{path})"
    end

    def modules
      return @modules unless @modules.nil?
      unless File.file?(puppetfile_path)
        warn "Puppetfile does not exist at #{puppetfile_path}"
        exit 1
      end
      puppetfile = Puppetfile.new
      puppetfile.instance_eval(File.read(puppetfile_path), puppetfile_path)
      @modules = puppetfile.modules
    end

    def module_version(name)
      modules.each do |mod|
        return mod[:version] if mod[:name].eql?(name) && !mod[:version].nil?
      end
      nil
    end

    def git(*command)
      argv = %w[git]
      argv << '--git-dir' << File.join(path, '.git')
      argv << '--work-tree' << path
      argv.concat(command)
      `#{argv.join(' ')}`
    end

    def environments_with_module(module_name, remote='origin')
      info "Searching for environments with module #{module_name}"
      git('for-each-ref', '--format', '"%(refname:short)"', "refs/remotes/#{remote}").each_line do |ref|
        info "Processing branch #{ref}"
      end
      []
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
      author, name = name.split /[-\/]/
      @modules << { name: name, author: author, version: version, args: args }
    end

    def to_s
      @modules.map {|mod| "#{mod[:name]} #{mod[:version]}" }.join(' ')
    end

    def method_missing(method, *args)
    end
  end
end
