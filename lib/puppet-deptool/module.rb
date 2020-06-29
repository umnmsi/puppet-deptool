require 'puppet-deptool/base'

module PuppetDeptool
  class Module < Base
    include Git

    attr_accessor :name, :path, :metadata_path, :dependencies

    def initialize(opts)
      super
      raise 'Required parameter :path missing' if opts[:path].nil?
      @path = options[:path]
      @metadata_path = File.join(path, 'metadata.json')
      @dependencies = Hash[DEPENDENCY_TYPES.map { |type| [type, {}] }]
    end

    def name
      @name ||= if Util.is_control_repo?(path)
                  File.basename(path)
                elsif File.exist?(metadata_path)
                  metadata['name'].sub(MODULE_NAME_PATTERN, '\2')
                elsif File.exist?(File.join(path, 'manifests'))
                  File.basename(path).sub(MODULE_NAME_PATTERN, '\2')
                else
                  ''
                end
    end

    def version
      @version ||= metadata['version']
    end

    def ref
      return @ref unless @ref.nil?
      @ref = Dir.chdir(path) do
        git(['ls-files', '--error-unmatch', path, '>/dev/null 2>&1'])
        current_commit
      end
    rescue GitError => e
      debug "Failed to get current ref for #{path}: #{e}"
      @ref = version
    end

    def author
      @author ||= if m = MODULE_NAME_PATTERN.match(metadata['name']) || m = MODULE_NAME_PATTERN.match(File.basename(path))
                    m[1]
                  else
                    metadata['author']
                  end
    end

    def to_s
      "#{author}-#{name} (#{path})"
    end

    def add_dependency(type, name, source)
      raise "Invalid dependency type #{type}" unless @dependencies.key? type
      # Don't add builtin variables
      return if type == :variable && name.start_with?('settings::')
      @dependencies[type][name] ||= []
      @dependencies[type][name] << source unless @dependencies[type][name].include? source
    end

    def metadata
      return @metadata unless @metadata.nil?
      unless File.file?(metadata_path)
        warn "Missing metadata file #{metadata_path}!" unless Util.warning_known?(:missing_metadata, name)
        return @metadata = { 'author' => 'msi', 'version' => '0.0.1' }
      end
      debug "Loading metadata from #{metadata_path}"
      raise "Unable to open metadata file #{metadata_path}!" unless File.readable?(metadata_path)
      @metadata = JSON.parse(File.read(metadata_path))
    end

    def update_metadata!(changes)
      info "Updating metadata #{metadata_path}"
      metadata.merge!(changes)
      File.open(metadata_path, 'w') do |file|
        file.truncate(0)
        file.write(JSON.pretty_generate(metadata))
      end
    end
  end
end
