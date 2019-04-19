require 'puppet-deptool/consts'
require 'puppet-deptool/logger'

module PuppetDeptool
  class Module
    include Consts
    include Logger

    NAME_PATTERN = %r{^([^-]+)[-/](.+)$}

    attr_accessor :name, :path, :metadata_path, :dependencies

    def initialize(options)
      @path = options[:path]
      @metadata_path = File.join(path, 'metadata.json')
      @dependencies = Hash[DEPENDENCY_TYPES.map { |type| [type, {}] }]
    end

    def is_control_repo?
      @is_control_repo ||= File.exist?(File.join(path, 'Puppetfile'))
    end

    def name
      @name ||= if is_control_repo?
                  File.basename(path)
                elsif File.exist?(File.join(path, 'metadata.json'))
                  metadata['name'].sub(NAME_PATTERN, '\2')
                elsif File.exist?(File.join(path, 'manifests'))
                  File.basename(path).sub(NAME_PATTERN, '\2')
                end
    end

    def version
      @version ||= metadata['version']
    end

    def author
      @author ||= if m = NAME_PATTERN.match(metadata['name']) || m = NAME_PATTERN.match(File.basename(path))
                    m[1]
                  else
                    metadata['author']
                  end
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
        warn "Missing metadata file #{metadata_path}!"
        return @metadata = { 'author' => 'msi', 'version' => '0.0.1' }
      end
      info "Loading metadata from #{metadata_path}"
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
