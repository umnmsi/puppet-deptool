require 'puppet'
require 'puppet/datatypes/impl/error'
require 'find'
require 'fileutils'
require 'generate_puppetfile'
require 'pp'
require 'json'
require 'puppet-deptool/base'
require 'puppet-deptool/warning_dsl'
require 'puppet-deptool/module'
require 'r10k/puppetfile'

module Puppet::Environments
  # Enable Puppet::Environments::StaticDirectory Loaders support
  class StaticDirectory
    def get_conf(name)
      return nil unless name == @env_name
      Puppet::Settings::EnvironmentConf.load_from(@env_dir, [])
    end
  end
end

# Parses and resolves module dependencies
module PuppetDeptool
  class Parser < Base
    attr_accessor :dependencies, :warnings_encountered

    def initialize(opts)
      $stdout.sync = true
      opts = Parser.default_options.merge(opts)
      super(opts)

      Puppet.settings[:environment] = ENV_NAME
      Puppet.settings[:vardir] = '/dev/null'

      @environment = Puppet::Node::Environment.create(ENV_NAME, [])
      @basedir = options[:basedir]
      @module = Module.new(path: @basedir)

      validate_options

      @env_pn = Pathname.new(@environment_path)
      @parser = Puppet::Pops::Parser::EvaluatingParser.singleton
      @loaders = Puppet::Pops::Loaders.new(@environment, true)
      #@dumper = Puppet::Pops::Model::ModelTreeDumper.new
      @definitions = Hash[DEFINITION_TYPES.map { |type| [type, {}] }]
      @inherits = {}
      @modules = {}
      @builtin_types = []
      @builtin_providers = {}
      @unhandled_pops_types = []
      @warnings_encountered = false
    end

    def validate_options
      debug "Validating options"
      if @module.name.empty?
        warn "basedir #{@basedir} doesn't appear to be a valid module or control repo!"
        exit 1
      end
      if options[:controldir]
        @control_repo = PuppetDeptool.control_repo(path: options[:controldir])
        @environment_path = options[:controldir]
        options[:use_env_modulepath] = true if options[:modulepath].empty?
      elsif Util.is_control_repo?(@basedir)
        info "Found control repository"
        @control_repo = PuppetDeptool.control_repo(path: @basedir)
        @environment_path = @basedir
        options[:use_env_modulepath] = true if options[:modulepath].empty?
      elsif options[:modulepath].empty? || options[:use_env_modulepath]
        if options[:modulepath].empty? && File.directory?('spec/fixtures/modules') && !options[:environment]
          info "Found modules directory at spec/fixtures/modules. Path references will be relative to spec/fixtures directory."
          @environment_path = File.expand_path('spec/fixtures')
          options[:modulepath] = [File.expand_path('spec/fixtures/modules')]
        else
          unless options[:environment]
            info "No control repository, modulepath or environment specified. Assuming default environment #{DEFAULT_ENVIRONMENT}"
            options[:environment] = DEFAULT_ENVIRONMENT
            options[:deploy_environment] = options[:force] = true
          end
          unless @control_repo = Util.environment_to_control_repo(options[:environment])
            warn "Failed to clone environment #{options[:environment]}"
            exit 1
          end
          options[:use_env_modulepath] = true if options[:modulepath].empty?
          @environment_path = @control_repo.path
        end
      end
      if @environment_path.nil?
        warn "Failed to determine environment path. Check your control-dir, modulepath and environment parameters."
        exit 1
      end

      info "Found environment_path #{@environment_path}"

      [:use_generated_state, :deploy_environment, :update_fixtures, :validate_state].each do |option|
        if options[option] && @control_repo.nil?
          warn "--#{option.to_s.gsub('_', '-')} specified but no control repository found"
          exit 1
        end
      end
      [:generate_warnings_file, :generate_state_file].each do |option|
        if options[option] && ! Util.is_control_repo?(@basedir)
          warn "--#{option.to_s.gsub('_', '-')} is only valid for control repositories"
          exit 1
        end
      end

      unless @control_repo.nil?
        options[:state_file] ||= File.join(@control_repo.path, PuppetDeptool::DEPTOOL_DIR, 'state')
        options[:known_warnings_file] ||= File.join(@control_repo.path, PuppetDeptool::DEPTOOL_DIR, 'known_warnings')
      end

      if options[:use_generated_state]
        if File.file? options[:state_file]
          # Rescan current module when using generated state
          if options[:scan_modules].empty?
            options[:scan_modules] = [@module.name]
            # Add role/profile 'modules' if control repo
            options[:scan_modules] += CONTROL_MODULES if Util.is_control_repo?(@basedir)
            options[:rescan_listed_modules] = true
          end
        else
          warn "--use-generated-state was specified, but state file #{options[:state_file]} does not exist in environment #{options[:environment]}. Deploying environment for full scan and resolve."
          options[:use_generated_state] = false
          options[:validate_state] = false
          options[:deploy_environment] = true
        end
      end

      options[:modulepath] = [create_tmp_modulepath([@module])] if options[:modulepath].empty? && !Util.is_control_repo?(@basedir)

      environments = Puppet::Environments::StaticDirectory.new(ENV_NAME, @environment_path, @environment)
      Puppet.push_context(environments: environments, current_environment: @environment)
      Puppet.settings.initialize_app_defaults(Puppet::Settings.app_defaults_for_run_mode(Puppet::Util::UnixRunMode.new(:master)))

      # Add environment.conf modulepath if requested
      if options[:modulepath].empty? || options[:use_env_modulepath]
        info "Adding environment.conf modulepath to modulepath"
        options[:modulepath] = options[:modulepath].concat(Puppet
                           .settings
                           .value(:modulepath, Parser::ENV_NAME, true)
                           .split(File::PATH_SEPARATOR)
                           .reject { |path| path.start_with? '$' })

      end

      info "Found modulepath #{options[:modulepath].join(':')}"

      # Validate modulepath unless deploying environment
      validate_modulepath unless options[:deploy_environment]
    end

    def deploy_environment
      info "Deploying environment #{@control_repo.current_environment.name}"
      @control_repo.current_environment.deploy(force: options[:force])
      validate_modulepath
    end

    def validate_modulepath
      options[:modulepath].each do |path|
        debug "Validating modulepath #{path}"
        unless Dir.exist? path
          warn "modulepath directory #{path} does not exist"
          exit 1
        end
      end
    end

    def list_dependencies
      if @dependencies.nil?
        warn 'No dependencies defined! Did you run resolve?'
        return
      end
      puts @dependencies.join ' '
    end

    def update_metadata
      mod_deps = dependencies.map do |dep|
        mod = get_module(dep)
        min_version = if @control_repo.nil?
                        mod.version
                      else
                        @control_repo.current_environment.module_version(dep) || mod.version
                      end
        max_version = "#{min_version.split('.')[0].to_i + 1}.0.0"
        { 'name' => "#{mod.author}-#{mod.name}", 'version_requirement' => ">= #{min_version} < #{max_version}" }
      end
      @module.update_metadata!('dependencies' => mod_deps)
    end

    def update_fixtures
      flags = []
      if @module.trivial?
        flags.concat(['--modulepath', '..'])
      end
      args = ['-p', @control_repo.current_environment.puppetfile_path, '--fixtures-only', '--use-refs', '--modulename', @module.name, *flags, *@dependencies]
      info 'Generating .fixtures.yml...'
      debug "  with args #{args}"
      GeneratePuppetfile::Bin.new(args).run
    end

    def load_state
      collect_builtins
      info "Loading state file #{options[:state_file]}"
      File.open(options[:state_file], 'r') do |file|
        modules_to_exclude = ['builtin']
        modules_to_exclude += options[:scan_modules] if options[:rescan_listed_modules]
        state = Marshal.load(file)
#        puts state.pretty_inspect
        state['definitions'].each do |type, defs|
          defs.each do |definition, mod|
            add_definition type, definition, mod unless modules_to_exclude.include? mod
          end
        end
        @modules = state['modules'].reject { |mod, info| modules_to_exclude.include? mod }
      end
    end

    def generate_state
      FileUtils.mkdir_p(File.dirname(options[:state_file]))
      File.open(options[:state_file], 'w') do |file|
        file.truncate(0)
        file.write(Marshal.dump({
          'definitions' => @definitions,
          'modules' => @modules,
        }))
      end
    end

    def validate_state
      info "Validating state file"
      env = @control_repo.current_environment
      puppetfile = R10K::Puppetfile.new(@control_repo.path)
      puppetfile.load!
      puppetfile.modules.each do |mod|
        info "Checking Puppetfile module #{mod.name}"
        next if options[:rescan_listed_modules] && options[:scan_modules].include?(mod.name)
        state_ref = get_module(mod.name).ref
        target_ref = if mod.is_a? R10K::Module::Git
                       mod.repo.resolve(mod.desired_ref)
                     elsif mod.is_a? R10K::Module::Forge
                       mod.expected_version
                     else
                       raise "Unknown R10K module type #{mod}"
                     end
        if state_ref != target_ref
          warn "State file module ref #{state_ref} does not match Puppetfile ref #{target_ref}"
        end
      end
    end

    def load_known_warnings
      return unless !@control_repo.nil? && File.exist?(options[:known_warnings_file])
      info "Loading known warnings from #{options[:known_warnings_file]}"
      dsl = WarningsDSL.new(Util.known_warnings)
      begin
        contents = File.read(options[:known_warnings_file])
        dsl.instance_eval contents, options[:known_warnings_file]
      rescue ArgumentError => e
        STDERR.puts "Error while parsing known warnings: #{e}"
        exit 1
      end
    end

    def generate_known_warnings
      FileUtils.mkdir_p(File.dirname(options[:known_warnings_file]))
      File.open(options[:known_warnings_file], 'w') do |file|
        file.truncate(0)
        Util.found_warnings.each do |type, warnings|
          warnings.each do |warning|
            file.puts "#{type} #{WARNING_TYPES[type].map do |attr|
              "#{attr}: #{warning[attr].is_a?(Symbol) ? ":#{warning[attr]}" : "'#{warning[attr]}'"}"
            end.join(', ')}"
          end
        end
      end
    end

    def warning_known?(warning_type, *args)
      Util.warning_known?(warning_type, *args)
    end

    def collect_builtins
      return unless @builtin_types.empty?
      info "Loading built-in types, providers and functions"
      Puppet::Type.loadall
      Puppet::Type.eachtype do |type|
        @builtin_types << type
        add_definition :resource_type, type.name, 'builtin'
        type.providers.each do |provider|
          provider_name = "#{type.name}/#{provider}"
          warn "Found duplicate provider #{provider_name}" if @builtin_providers.key? provider_name
          @builtin_providers[provider_name] = { type: type, provider: provider }
          add_definition :provider, provider_name, 'builtin'
        end
      end
      Puppet::Util::Autoload.files_to_load('puppet/provider', @environment).each do |file|
        name = File.basename(file, '.rb')
        add_definition :provider, name, 'builtin'
      end
      Puppet::Pops::Types::TypeParser.type_map.keys.map do |type|
        add_definition :datatype, type, 'builtin'
      end
      Puppet::Util::Autoload.files_to_load('puppet/parser/functions', @environment).each do |file|
        name = File.basename(file, '.rb')
        add_definition :function_3x, name, 'builtin'
      end
      Puppet::Util::Autoload.files_to_load('puppet/functions', @environment).each do |file|
        name = File.basename(file, '.rb')
        add_definition :function, name, 'builtin'
      end
      Puppet::Pops::Loader::StaticLoader::BUILTIN_ALIASES.keys.each do |type|
        add_definition :type_alias, type.downcase, 'builtin'
      end
    end

    def get_module(modname)
      return @modules[modname] if @modules.key? modname
      raise "No module #{modname} found"
    end

    def set_module(modname, data)
      @modules[modname] = data
    end

    def create_tmp_modulepath(modules)
      raise "#{__method__} requires an array of modules to link" unless modules.is_a? Array
      tmpdir = Dir.mktmpdir('modules')
      modules.each do |mod|
        FileUtils.symlink(mod.path, File.join(tmpdir, mod.name))
      end
      tmpdir
    end

    def add_definition(type, name, source = @current_module.name, ignore_dup = false)
      debug "Adding #{type} definition #{name} from #{source}:#{@current_file}"
      name = name.to_s.sub(%r{^::}, '')
      raise "Invalid definition type #{type}" unless @definitions.key? type
      if @definitions[type].key?(name) && !ignore_dup
        unless warning_known? :duplicate_definition, type, name, source
          warn "#{type} #{name} (#{source}): Already defined in #{@definitions[type][name]}"
        end
      end
      @definitions[type][name] = source
    end

    def add_dependency(type, name, source = @current_module)
      debug "Adding #{type} dependency #{name} from #{source}:#{@current_file}"
      name = name.to_s.sub(%r{^::}, '')
      source.add_dependency(type, name, @current_file)
    end

    def parse_file(file)
      debug "Parsing #{file}"
      @current_file = Pathname.new(file).relative_path_from(@env_pn).to_s
      @literal_strings = []
      @qualified_names = []
      results = @parser.parse_file(file)
      trace results.locator.string
      process_result results
      @literal_strings.each do |literal_string|
        warn "Unresolved literal string in #{file}: '#{literal_string}'"
      end
      @qualified_names.each do |qualified_name|
        warn "Unresolved qualified name in #{file}: '#{qualified_name}'"
      end
    end

    def scan
      collect_builtins
      return if options[:use_generated_state] && options[:scan_modules].empty?
      modules_to_scan = if !options[:scan_modules].empty?
                          options[:scan_modules]
                        elsif options[:restrict_scan]
                          options[:modules]
                        else
                          []
                        end
      info modules_to_scan.empty? ?
        "Scanning all modules" :
        "Found modules_to_scan #{modules_to_scan}"
      unless @control_repo.nil?
        control_mod = Module.new(path: @control_repo.path)
        scan_module(control_mod) if modules_to_scan.empty? || modules_to_scan.include?(control_mod.name)
      end
      options[:modulepath].each do |path|
        info "Processing modulepath #{path}"
        Dir.entries(path).each do |name|
          debug "Processing modulepath file #{name}" unless ['.', '..'].include? name
          next unless Puppet::Module.is_module_directory?(name, path)
          mod = Module.new(path: File.join(path, name))
          next unless modules_to_scan.empty? || modules_to_scan.include?(mod.name)
          if @modules.include? mod.name
            info "Module #{mod.name} already processed. Skipping"
            next
          end
          scan_module(mod)
        end
      end
      unscanned_modules = modules_to_scan.empty? ? (options[:modules] - @modules.keys) : (modules_to_scan - @modules.keys)
      unless unscanned_modules.empty?
        warn "Failed to scan module(s) #{unscanned_modules.join ', '}"
      end
      unless @unhandled_pops_types.empty?
        warn 'The following unknown Puppet::Pops types were encountered'
        warn @unhandled_pops_types.sort.uniq.pretty_inspect
      end
      debug 'Definitions:'
      debug @definitions.pretty_inspect
      debug 'Modules:'
      debug @modules.pretty_inspect
    end

    def scan_module(mod)
      path = mod.path
      unless mod.name
        warn "#{path} doesn't appear to be a module directory. Skipping path."
        return
      end
      @current_module = mod
      @current_class = nil
      info "Scanning module #{mod.name} (#{path}) ref #{mod.ref}/version #{mod.version}"

      # Process .pp files
      pp_dirs = ['manifests', 'functions', 'types']
      pp_dirs.each do |dir|
        pattern = File.join(path, dir, '**', '*.pp')
        debug "Searching Puppet #{dir} with pattern #{pattern}"
        Dir.glob(pattern) do |file|
          next if File.directory?(file)
          parse_file(file)
        end
      end

      # Module plugin directory
      plugindir = File.join(path, 'lib')

      $LOAD_PATH.unshift(plugindir)

      # Process 3x ruby functions
      pattern = File.join(plugindir, 'puppet', 'parser', 'functions', '*.rb')
      debug "Loading ruby custom 3x functions with pattern #{pattern}"
      Dir.glob(pattern).each do |file|
        begin
          debug "Loading #{file}"
          Kernel.load file
        rescue => e
          warn "Failed to load #{file}: #{e.message} #{e.backtrace}"
        end
      end
      functions = Puppet::Parser::Functions.environment_module(@environment).all_function_info
      debug "Found functions #{functions.keys.sort.join(', ')}" unless functions.empty?
      functions.each { |function, _| add_definition :function_3x, function }
      Puppet::Parser::Functions::AnonymousModuleAdapter.clear(@environment)

      # Process 4x ruby functions and datatypes
      debug 'Loading ruby functions and datatypes'
      mod = Puppet::Module.new(@current_module.name, path, @environment)
      @environment.instance_variable_set(:@modules, [mod])
      loader = Puppet::Pops::Loader::ModuleLoaders::FileBased.new(@loaders.static_loader, @loaders, mod.name, mod.path, mod.name, [:func_4x, :datatype])
      loader.private_loader = Puppet::Pops::Loader::DependencyLoader.new(loader, "#{mod.name} private", [loader])
      [:function, :datatype].each do |type|
        errors = []
        discover_type = if type == :datatype
                          :type
                        else
                          type
                        end
        builtin = loader.parent.discover(discover_type, errors)
        results = loader.discover(discover_type, errors)
        diff = results - builtin
        errors.each do |error|
          warn "Found #{type} error #{error}" unless warning_known? :type_error, type, error, source
        end
        debug "Found #{type}s #{diff.map { |result| result.name }.sort.join(', ')}" unless diff.empty?
        diff.each { |result| add_definition type, result.name }
      end

      # Create environment using full modulepath so dependencies can be autoloaded
      environment = Puppet::Node::Environment.create(ENV_NAME, options[:modulepath])
      environments = Puppet::Environments::StaticDirectory.new(ENV_NAME, @environment_path, environment)
      Puppet.push_context(environments: environments, current_environment: environment)

      # Process custom types
      pattern = File.join(plugindir, 'puppet', 'type', '*.rb')
      debug "Loading ruby custom types with pattern #{pattern}"
      new_types = []
      load_pattern(pattern, /puppet#{File::SEPARATOR}type#{File::SEPARATOR}(?<type>[^#{File::SEPARATOR}]+)\.rb$/) do |match|
        if type = Puppet::Type.type(match[:type])
          new_types += [type.name]
          add_definition :resource_type, type.name
        else
          warn "Failed to find type #{match[:type]} after loading file"
        end
      end
      debug "Found custom types #{new_types.sort.join(', ')}" unless new_types.empty?

      # Process custom provider classes
      pattern = File.join(plugindir, 'puppet', 'provider', '*.rb')
      debug "Loading custom provider classes with pattern #{pattern}"
      new_provider_classes = []
      load_pattern(pattern, /puppet#{File::SEPARATOR}provider#{File::SEPARATOR}(?<provider>.*)\.rb$/) do |match|
        if Puppet::Provider.constants(false).include? match[:provider].capitalize.to_sym
          new_provider_classes += [match[:provider]]
          add_definition :provider, match[:provider]
        else
          warn "Failed to find provider #{match[:provider]} after loading file"
        end
      end
      debug "Found custom provider classes #{new_provider_classes.sort.join(', ')}" unless new_provider_classes.empty?

      # Process custom providers
      pattern = File.join(plugindir, 'puppet', 'provider', '*', '*.rb')
      debug "Loading ruby custom providers with pattern #{pattern}"
      new_providers = []
      load_pattern(pattern, /puppet#{File::SEPARATOR}provider#{File::SEPARATOR}(?<type>[^#{File::SEPARATOR}]+)#{File::SEPARATOR}(?<provider>.*)\.rb$/) do |match|
        if type = Puppet::Type.type(match[:type])
          if provider = type.provider(match[:provider])
            new_providers += ["#{type.name}/#{match[:provider]}"]
            add_definition :provider, "#{type.name}/#{match[:provider]}"
            add_dependency :resource_type, type.name
            provider.singleton_class.ancestors.select {|a| a.is_a? Class}.map(&:to_s).each do |ancestor|
              next if ancestor.eql?(provider.singleton_class.to_s)
              debug "Checking #{ancestor} for dependencies..."
              ancestor.match(/Puppet::Provider::(?<provider>\w+)/) do |match|
                add_dependency :provider, match[:provider].downcase
              end
              ancestor.match(/Puppet::Type::(?<type>[^:]+)::Provider(?<provider>\w+)/) do |match|
                add_dependency :provider, "#{match[:type].downcase}/#{match[:provider].downcase}"
              end
              ancestor.match(/Puppet::Type::(?<type>[^:]+)/) do |match|
                add_dependency :resource_type, "#{match[:type].downcase}"
              end
            end
          else
            warn "Failed to find provider #{match[:provider]} for type #{type} after loading file"
          end
        else
          warn "Failed to find type #{match[:type]} after loading file"
        end
      end
      debug "Found custom providers #{new_providers.sort.join(', ')}" unless new_providers.empty?

      Puppet.pop_context

      $LOAD_PATH.delete(plugindir)

      set_module(mod.name, @current_module)
    end

    def load_pattern(file_pattern, match_pattern, &block)
      Dir.glob(file_pattern).each do |file|
        begin
          @current_file = file
          if match = file.match(match_pattern)
            if $LOADED_FEATURES.include? match[0] # pupppet < 6.0.0 uses relative paths, e.g. puppet/type/newtype.rb
              debug "#{file} already loaded"
            elsif $LOADED_FEATURES.include? file
              debug "#{file} already loaded"
            else
              debug "Loading #{file}"
              Kernel.load file
            end
            block.call(match)
          else
            warn "Failed to determine name from #{file} using pattern #{match_pattern}"
          end
        rescue LoadError => e
          warn "Failed to load #{file}: #{e.message}\n#{e.backtrace.pretty_inspect}"
        rescue => e
          warn "Failed to load #{file}: #{e.message}\n#{e.backtrace.pretty_inspect}"
        end
      end
    end

    def resolve
      raise 'No parsed modules found! Did you run `rake spec_prep` or `pdk test unit` first?' if @modules.empty?
      info "Resolving dependencies"
      dependencies = []
      # Process any inherited classes
      inherited_variables = {}
      @inherits.each do |child, parent|
        @definitions[:variable].map do |variable, mod|
          if variable.start_with? "#{parent}::"
            inherited_variables[variable.sub(parent, child)] = mod
          end
        end
      end
      @definitions[:variable].merge! inherited_variables
      modules_to_resolve = options[:modules].empty? ? @modules.clone : @modules.select { |name, _mod| options[:modules].include? name }
      resolved_modules = []
      until modules_to_resolve.empty?
        name, mod = modules_to_resolve.shift
        info "Resolving module #{name}"
        module_deps = []
        mod.dependencies.each do |type, dependency_list|
          dependency_list.each do |dependency, sources|
            found = false
            if @definitions.key?(type) && @definitions[type].include?(dependency)
              module_deps << @definitions[type][dependency]
              found = true
            elsif type == :type
              if @definitions[:resource_type].include? dependency
                module_deps << @definitions[:resource_type][dependency]
                found = true
              elsif @definitions[:defined_type].include? dependency
                module_deps << @definitions[:defined_type][dependency]
                found = true
              elsif @definitions[:datatype].include? dependency
                module_deps << @definitions[:datatype][dependency]
                found = true
              elsif @definitions[:type_alias].include? dependency
                module_deps << @definitions[:type_alias][dependency]
                found = true
              end
            elsif type == :resource_type
              if @definitions[:defined_type].include? dependency
                module_deps << @definitions[:defined_type][dependency]
                found = true
              elsif @definitions[:datatype].include? dependency
                module_deps << @definitions[:datatype][dependency]
                found = true
              end
            elsif type == :function
              if @definitions[:function_3x].include? dependency
                module_deps << @definitions[:function_3x][dependency]
                found = true
              end
            elsif type == :provider
              # Check if type is a known defined type
              dependency.match(%r{(?<type>.+)/.+}) do |match|
                if @definitions[:defined_type].include? match[:type]
                  module_deps << @definitions[:defined_type][match[:type]]
                  found = true
                end
              end
            end
            if found
              debug "Found dependency #{module_deps.last} for #{type} #{dependency}"
              next
            end
            unknown_warning_sources = sources.reject { |source| warning_known? :missing_definition, type, dependency, source }
            next if unknown_warning_sources.empty?
            warn "Failed to find #{type} #{dependency}. Sources #{unknown_warning_sources.join(', ')}"
          end
        end
        # Remove self and builtin
        module_deps = (module_deps - ['builtin', name]).sort.uniq
        unless CONTROL_MODULES.include?(name) || Util.is_control_repo?(mod.path)
          CONTROL_MODULES.each do |control_module|
            next unless module_deps.include? control_module
            next if warning_known? :control_dependency, name
            warn "WARNING: Module #{name} depends on control repo module '#{control_module}'"
          end
        end
        debug "Found #{name} dependencies #{module_deps}"
        resolved_modules << name
        if options[:recurse]
          module_deps.each do |dep|
            unless CONTROL_MODULES.include?(dep) || resolved_modules.include?(dep)
              modules_to_resolve[dep] = get_module(dep)
            end
          end
        end
        dependencies += module_deps
      end
      @dependencies = (dependencies + options[:extra_dependencies] - [@module.name]).sort.uniq
    end

    # rubocop:disable Metrics/BlockNesting
    def process_result(result, parents = [], indent = 0)
      trace_write "%#{indent}sFound %s" % ['', result.class]
      begin
        case result
        when Puppet::Pops::Model::Parameter
          trace_write " '#{result.name}'"
        when Puppet::Pops::Model::LiteralFloat
          trace_write " '#{result.value}'"
        when Puppet::Pops::Model::LiteralInteger
          trace_write " '#{result.value}'"
        when Puppet::Pops::Model::RelationshipExpression
          trace_write " '#{result.operator}'"
        when Puppet::Pops::Model::MatchExpression
          trace_write " '#{result.operator}'"
        when Puppet::Pops::Model::LiteralBoolean
          trace_write " '#{result.value}'"
        when Puppet::Pops::Model::LiteralRegularExpression
          trace_write " '#{result.pattern}'"
        when Puppet::Pops::Model::ArithmeticExpression
          trace_write " '#{result.operator}'"
        when Puppet::Pops::Model::AttributeOperation
          trace_write " '#{result.attribute_name}'"
          if result.attribute_name == 'provider'
            resource_index = parents.reverse.find_index do |parent|
              trace "Checking parent class #{parent.class}"
              [
                Puppet::Pops::Model::CollectExpression,
                Puppet::Pops::Model::ResourceDefaultsExpression,
                Puppet::Pops::Model::ResourceExpression,
                Puppet::Pops::Model::ResourceOverrideExpression,
              ].include? parent.class
            end
            if resource_index == nil
              warn 'Failed to find parent resource for provider attribute'
            else
              resource = parents.reverse[resource_index]
              case resource
              when Puppet::Pops::Model::ResourceExpression
                type_result = resource.type_name
              when Puppet::Pops::Model::CollectExpression
                type_result = resource.type_expr
              when Puppet::Pops::Model::ResourceDefaultsExpression
                type_result = resource.type_ref
              when Puppet::Pops::Model::ResourceOverrideExpression
                type_result = resource.resources.left_expr
              else
                raise "Unhandled model #{resource.class}: #{resource}"
              end
              case type_result
              when Puppet::Pops::Model::QualifiedName, Puppet::Pops::Model::QualifiedReference
                case result.value_expr
                when Puppet::Pops::Model::QualifiedName, Puppet::Pops::Model::LiteralString
                  add_dependency :provider, "#{type_result.value}/#{result.value_expr.value}"
                when Puppet::Pops::Model::VariableExpression
                else
                  raise "Unknown AttributeOperation value_expr #{result.value_expr.class}"
                end
              else
                raise "Unknown provider parent model #{type_result.class}: #{type_result}" unless [
#                  Puppet::Pops::Model::AccessExpression, # Resource['file'] { '/tmp': }
                ].include? type_result.class
              end
            end
          end
        when Puppet::Pops::Model::LiteralDefault
          trace_write ' <default>'
        when Puppet::Pops::Model::LiteralUndef
          trace_write ' <undef>'
        when Puppet::Pops::Model::Nop
          trace_write ' <noop>'
        when Puppet::Pops::Model::LiteralString
          trace_write " '#{result.value}'"
          if parents.any? do |parent|
            [
              Puppet::Pops::Model::Parameter,
              Puppet::Pops::Model::CaseOption,
              Puppet::Pops::Model::LiteralList,
              Puppet::Pops::Model::ConcatenatedString,
              Puppet::Pops::Model::AssignmentExpression,
              Puppet::Pops::Model::MatchExpression,
              Puppet::Pops::Model::SelectorEntry,
              Puppet::Pops::Model::CallNamedFunctionExpression,
              Puppet::Pops::Model::KeyedEntry,
              Puppet::Pops::Model::ComparisonExpression,
              Puppet::Pops::Model::AttributeOperation,
              Puppet::Pops::Model::AccessExpression,
              Puppet::Pops::Model::SubLocatedExpression,
              Puppet::Pops::Model::IfExpression,
              Puppet::Pops::Model::NamedAccessExpression,
              Puppet::Pops::Model::CallMethodExpression,
            ].include? parent.class
          end
          @literal_strings.reject! { |name| name.object_id == result.object_id }
          else
            trace_write ' UNRESOLVED' unless @literal_strings.reject! { |name| name.object_id == result.object_id }
          end
        when Puppet::Pops::Model::QualifiedName
          trace_write " '#{result.value}'"
          if parents.any? do |parent|
            [
              Puppet::Pops::Model::Parameter,
              Puppet::Pops::Model::AttributeOperation,
              Puppet::Pops::Model::KeyedEntry,
              Puppet::Pops::Model::SelectorEntry,
              Puppet::Pops::Model::CollectExpression,
              Puppet::Pops::Model::CaseOption,
              Puppet::Pops::Model::CallNamedFunctionExpression,
            ].include? parent.class
          end
          @qualified_names.reject! { |name| name.object_id == result.object_id }
          else
            trace_write ' UNRESOLVED' unless @qualified_names.reject! { |name| name.object_id == result.object_id }
          end
        when Puppet::Pops::Model::HostClassDefinition
          trace_write " '#{result.name}'"
          add_definition :class, result.name.downcase
          @current_class = result.name
          result.parameters.each do |parameter|
            add_definition :variable, [@current_class, parameter.name.downcase].join('::')
          end
          unless result.parent_class.nil?
            trace_write " (inherits #{result.parent_class})"
            @inherits[result.name] = result.parent_class
          end
        when Puppet::Pops::Model::QualifiedReference
          trace_write " '#{result.cased_value}'"
          add_dependency :type, result.value
        when Puppet::Pops::Model::TypeAlias
          trace_write " #{result.name}"
          add_definition :type_alias, result.name.downcase
        when Puppet::Pops::Model::FunctionDefinition
          trace_write " #{result.name}"
          add_definition :function, result.name
        when Puppet::Pops::Model::ResourceTypeDefinition
          trace_write " #{result.name}"
          add_definition :defined_type, result.name
        when Puppet::Pops::Model::AssignmentExpression
          unless result.left_expr.class == Puppet::Pops::Model::VariableExpression
            raise "Unknown AssignmentExpression left_expr #{result.left_expr.class}"
          end
          case result.left_expr.expr
          when Puppet::Pops::Model::QualifiedName
            unless @current_class.nil?
              add_definition :variable, [@current_class, result.left_expr.expr.value].join('::'), @current_module.name, true
            end
            @qualified_names << result.left_expr.expr
          else
            raise "Unknown VariableExpression expr #{result.left_expr.expr.class}"
          end
        when Puppet::Pops::Model::ResourceDefaultsExpression
          unless result.type_ref.class == Puppet::Pops::Model::QualifiedReference
            raise "Unknown ResourceDefaultsExpression type_ref #{result.type_ref.class}"
          end
        when Puppet::Pops::Model::ResourceExpression # file { '/tmp': }
          case result.type_name
          when Puppet::Pops::Model::QualifiedName # file { '/tmp': }
            trace_write " '#{result.type_name.value}' (#{result.form})"
            add_dependency :resource_type, result.type_name.value
            @qualified_names << result.type_name
          else
            raise "Unknown ResourceExpression type_name #{result.type_name.class}" unless [
              Puppet::Pops::Model::AccessExpression, # Resource['file'] { '/tmp': }
            ].include? result.type_name.class
          end
          result.bodies.each do |body|
            case body.title
            when Puppet::Pops::Model::LiteralString
              # Add body title to deps if class
              if result.type_name.class == Puppet::Pops::Model::QualifiedName && result.type_name.value == 'class'
                add_dependency :class, body.title.value.downcase
              end
              @literal_strings << body.title
            when Puppet::Pops::Model::QualifiedName
              @qualified_names << body.title
            end
          end
        when Puppet::Pops::Model::CallMethodExpression
          unless result.functor_expr.class == Puppet::Pops::Model::NamedAccessExpression
            raise "Unknown CallMethodExpression functor_expr #{result.functor_expr.class}"
          end
          right_expr = result.functor_expr.right_expr
          unless right_expr.class == Puppet::Pops::Model::QualifiedName
            raise "Unknown NamedAccessExpression right_expr #{right_expr.class}"
          end
          add_dependency :function, right_expr.value
          @qualified_names << right_expr
        when Puppet::Pops::Model::CallNamedFunctionExpression
          case result.functor_expr
          when Puppet::Pops::Model::QualifiedName
            trace_write " '#{result.functor_expr.value}'"
            add_dependency :function, result.functor_expr.value
            @qualified_names << result.functor_expr
            if ['create_resources', 'ensure_resource'].include? result.functor_expr.value
              resource_type = result.arguments[0]
              case resource_type
              when Puppet::Pops::Model::QualifiedName
                add_dependency :resource_type, resource_type.value
                @qualified_names << resource_type
              when Puppet::Pops::Model::LiteralString
                add_dependency :resource_type, resource_type.value
                @literal_strings << resource_type
              else
                raise "Unknown create_resources/ensure_resource argument #{resource_type.class}" unless [
                  Puppet::Pops::Model::AccessExpression,
                  Puppet::Pops::Model::ConcatenatedString,
                ].include? resource_type.class
              end
            end
          when Puppet::Pops::Model::QualifiedReference
            trace_write " '#{result.functor_expr.value}'"
          else
            raise "Unknown CallNamedFunctionExpression functor_expr #{result.functor_expr.class}"
          end
          if ['include', 'require', 'contain'].include? result.functor_expr.value
            result.arguments.each do |argument|
              case argument
              when Puppet::Pops::Model::QualifiedName
                add_dependency :class, argument.value.downcase
                @qualified_names << argument
              when Puppet::Pops::Model::LiteralString
                add_dependency :class, argument.value.downcase
                @literal_strings << argument
              else
                raise "Unknown include/require/contain arg #{argument.class}" unless [
                  Puppet::Pops::Model::ConcatenatedString,
                  Puppet::Pops::Model::VariableExpression,
                ].include? argument.class
              end
            end
          end
        when Puppet::Pops::Model::VariableExpression
          case result.expr
          when Puppet::Pops::Model::QualifiedName
            if result.expr.value.match? %r{\w::}
              add_dependency :variable, result.expr.value
            end
            @qualified_names << result.expr
          else
            raise "Unknown VariableExpression expr #{result.expr.class}"
          end
        when Puppet::Pops::Model::AccessExpression
          case result.left_expr
          when Puppet::Pops::Model::QualifiedReference, Puppet::Pops::Model::VariableExpression
            result.keys.each do |key|
              case key
              when Puppet::Pops::Model::LiteralString
                if result.left_expr.class == Puppet::Pops::Model::QualifiedReference
                  if result.left_expr.value == 'class'
                    add_dependency :class, key.value.downcase
                  elsif result.left_expr.value == 'resource'
                    add_dependency :resource_type, key.value.downcase
                  end
                end
                @literal_strings << key
              when Puppet::Pops::Model::QualifiedName
                if result.left_expr.class == Puppet::Pops::Model::VariableExpression
                  @qualified_names << key
                end
              end
            end
          else
            raise "Unknown AccessExpression left_expr #{result.left_expr.class}" unless [
              Puppet::Pops::Model::AccessExpression,
              Puppet::Pops::Model::CallNamedFunctionExpression,
              Puppet::Pops::Model::CallMethodExpression,
            ].include?(result.left_expr.class)
          end
        else
          unless [
            Puppet::Pops::Model::NamedAccessExpression,
            Puppet::Pops::Model::VirtualQuery,
            Puppet::Pops::Model::Program,
            Puppet::Pops::Model::BlockExpression,
            Puppet::Pops::Model::IfExpression,
            Puppet::Pops::Model::AndExpression,
            Puppet::Pops::Model::CaseExpression,
            Puppet::Pops::Model::CaseOption,
            Puppet::Pops::Model::InExpression,
            Puppet::Pops::Model::LiteralList,
            Puppet::Pops::Model::NotExpression,
            Puppet::Pops::Model::OrExpression,
            Puppet::Pops::Model::ParenthesizedExpression,
            Puppet::Pops::Model::ConcatenatedString,
            Puppet::Pops::Model::SelectorExpression,
            Puppet::Pops::Model::SelectorEntry,
            Puppet::Pops::Model::HeredocExpression,
            Puppet::Pops::Model::SubLocatedExpression,
            Puppet::Pops::Model::AttributesOperation,
            Puppet::Pops::Model::TextExpression,
            Puppet::Pops::Model::ComparisonExpression,
            Puppet::Pops::Model::LiteralHash,
            Puppet::Pops::Model::KeyedEntry,
            Puppet::Pops::Model::ResourceBody,
            Puppet::Pops::Model::UnaryMinusExpression,
            Puppet::Pops::Model::UnfoldExpression,
            Puppet::Pops::Model::LambdaExpression,
            Puppet::Pops::Model::CollectExpression,
            Puppet::Pops::Model::ExportedQuery,
            Puppet::Pops::Model::NodeDefinition,
            Puppet::Pops::Model::ResourceOverrideExpression,
            Puppet::Pops::Model::UnlessExpression,
            Puppet::Pops::Parser::Locator::Locator19,
          ].include?(result.class)
            @unhandled_pops_types << result.class.to_s
            trace_write ' UNRESOLVED'
          end
        end
        # trace_write @dumper.dump(result)
        trace_write "\n"
        result._pcore_contents { |content| process_result content, parents + [result], indent + 2 }
      rescue => e
        warn "Error while processing the following section of #{@current_file}:"
        warn result.locator.string[result.offset, result.length]
        warn e.message
        warn e.backtrace.map { |line| "    #{line}" }.join "\n"
        exit 1
      end
    end
    # rubocop:enable Metrics/BlockNesting

    class << self
      def default_options
        options = GLOBAL_DEFAULTS.dup
        options[:modules] = []
        options[:extra_dependencies] = []
        options[:recurse] = false
        options[:restrict_scan] = false
        options[:scan_modules] = []
        options[:basedir] = Dir.pwd
        options[:controldir] = nil
        options[:modulepath] = []
        options[:environment] = nil
        options[:deploy_environment] = false
        options[:force] = false
        options[:use_env_modulepath] = false
        options[:list_dependencies] = false
        options[:use_generated_state] = false
        options[:validate_state] = false
        options[:rescan_listed_modules] = false
        options[:generate_state_file] = false
        options[:generate_warnings_file] = false
        options[:update_metadata] = false
        options[:update_fixtures] = false
        options[:warnings_ok] = false
        # These two defaults are normally derived after arg parsing in parse_args
        options[:state_file] = options[:known_warnings_file] = nil
        options
      end

      def parse_args(opts = {})
        options = default_options.merge!(opts)
        optparser = OptionParser.new do |opts|
          PuppetDeptool.global_parser_options(opts, options)
          opts.on('-b', '--basedir DIR', 'Set base directory to DIR. Defaults to current directory.') do |basedir|
            unless Dir.exist? basedir
              warn "basedir #{basedir} does not exist"
              exit 1
            end
            options[:basedir] = File.expand_path(basedir)
          end
          opts.on('-c', '--controldir DIR', 'Set control repository directory to DIR.') do |controldir|
            unless Dir.exist? controldir
              warn "controldir #{controldir} does not exist"
              exit 1
            end
            unless Util.is_control_repo?(controldir)
              warn "controldir #{controldir} does not appear to be a control repository"
              exit 1
            end
            options[:controldir] = File.expand_path(controldir)
          end
          opts.on('-d', '--deploy-environment', 'Runs a full R10K deploy on controldir. Defaults to false.') do
            options[:deploy_environment] = true
          end
          opts.on('-e', '--environment ENVIRONMENT', 'Environment to check dependencies against. Implies --deploy-environment and --force.') do |envname|
            options[:environment] = envname
            options[:deploy_environment] = options[:force] = true
          end
          opts.on('-f', '--state-file FILE', "Path to file containing parsed state. Implies --use-generated-state. Defaults to ${controldir}/#{PuppetDeptool::DEPTOOL_DIR}/state.") do |path|
            options[:use_generated_state] = true
            options[:state_file] = path
          end
          opts.on('-g', '--generate-state-file', 'Generate state file. Only valid for control repositories.') do
            options[:generate_state_file] = true
          end
          opts.on('-k', '--known-warnings FILE', "Path to file containing known warnings to ignore. Defaults to ${controldir}/#{PuppetDeptool::DEPTOOL_DIR}/known_warnings.") do |path|
            options[:known_warnings_file] = path
          end
          opts.on('-l', '--list-deps', 'Print resolved dependencies.') do
            options[:list_dependencies] = true
          end
          opts.on('-m', '--module MODULE', 'Resolve dependenecies of MODULE. Can be specified multiple times.') do |mod|
            options[:modules] << mod
          end
          opts.on('-p', '--modulepath DIR', 'Set environment modulepath. Can be specified multiple times. Defaults to environment.conf modulepath.') do |modulepath|
            unless Dir.exist? modulepath
              warn "modulepath #{modulepath} does not exist"
              exit 1
            end
            options[:modulepath] << File.expand_path(modulepath)
          end
          opts.on('-r', '--recurse', 'Recursively determine module dependencies. Defaults to false.') do
            options[:recurse] = true
          end
          opts.on('-s', '--scan MODULE', 'Add MODULE to list of modules to scan. Defaults to scan all modules if not specified.') do |scan|
            options[:scan_modules] << scan
          end
          opts.on('-u', '--use-generated-state', 'Use generated state file instead of scanning. Only valid if --basedir is control repository or --control-dir/--environment are specified. Defaults to false.') do
            options[:use_generated_state] = true
          end
          opts.on('-w', '--warnings-ok', 'Return 0 exit code even if there are warnings. Defaults to false.') do
            options[:warnings_ok] = true
          end
          opts.on('-F', '--force', 'Overwrite local changes during deployment. Defaults to false.') do
            options[:force] = true
          end
          opts.on('-G', '--generate-warnings-file', 'Generate known warnings file for all current warnings.') do
            options[:generate_warnings_file] = true
          end
          opts.on('-M', '--update-metadata', 'Update metadata.json with resolved dependencies. Defaults to false.') do
            options[:update_metadata] = true
          end
          opts.on('-P', '--use-env-modulepath', 'Prepend module paths specified with --modulepath to modulepath in environment.conf') do
            options[:use_env_modulepath] = true
          end
          opts.on('-R', '--restrict', 'Restrict scanned modules to modules specified with --module. Default false.') do
            options[:restrict_scan] = true
          end
          opts.on('-S', '--rescan-listed-modules', 'Use generated state file but also rescan modules specified with --scan. Implies --use-generated-state. Defaults to false.') do
            options[:rescan_listed_modules] = options[:use_generated_state] = true
          end
          opts.on('-V', '--validate-state', 'Validates versions used in generated state match Puppetfile. Implies --use-generated-state') do
            options[:use_generated_state] = true
            options[:validate_state] = true
          end
          opts.on('-X', '--update-fixtures', 'Update .fixtures.yml with resolved dependencies. Defaults to false.') do
            options[:update_fixtures] = true
          end
          opts.on('-x', '--extra-dependencies MODULE', 'Additional modules to include in dependency list that are not detected by a scan.') do |mod|
            options[:extra_dependencies] << mod
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
