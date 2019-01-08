require 'puppet'
require 'puppet/datatypes/impl/error'
require 'find'
require 'fileutils'
require 'pp'
require 'json'
require 'puppet-deptool/logger'
require 'puppet-deptool/consts'
require 'puppet-deptool/dsl'

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
  class Parser
    include Logger
    include Consts

    attr_accessor :warnings_encountered

    def initialize(options)
      @options = options
      @parser = Puppet::Pops::Parser::EvaluatingParser.singleton
      @environment = Puppet::Node::Environment.create(ENV_NAME, [])
      @modulepath = options[:modulepath].empty? ? nil : options[:modulepath]
      @envdir = options[:envdir]
      @loaders = Puppet::Pops::Loaders.new(@environment, true)
      @dumper = Puppet::Pops::Model::ModelTreeDumper.new
      @definitions = Hash[DEFINITION_TYPES.map { |type| [type, {}] }]
      @inherits = {}
      @modules = {}
      @builtin_types = []
      @unhandled_pops_types = []
      @warnings_encountered = false

      @found_warnings = Hash[WARNING_TYPES.map { |type, _| [type, []] }]
      @known_warnings = Hash[WARNING_TYPES.map { |type, _| [type, []] }]

      @debug = options[:debug]
      @verbose = options[:verbose]
      @quiet = options[:quiet]

      validate_options
      load_known_warnings
    end

    def validate_options
      @envdir_info = get_module_info(@envdir)
      if @envdir_info[:name].empty?
        warn "envdir #{@envdir} doesn't appear to be an environment or module directory!"
        exit 1
      end
      if !@envdir_info[:is_control_repo] && @modulepath.nil?
        if File.directory?('spec/fixtures/modules')
          puts "Found modules directory at spec/fixtures/modules. Path references will be relative to spec/fixtures directory."
          @envdir = File.expand_path('spec/fixtures')
          @modulepath = [File.expand_path('spec/fixtures/modules')]
        else
          warn "envdir #{@envdir} doesn't appear to be an environment directory and no modulepath was provided!"
          exit 1
        end
      end
      @envdir_pn = Pathname.new(@envdir)
      environments = Puppet::Environments::StaticDirectory.new(ENV_NAME, @envdir, @environment)
      Puppet.push_context(environments: environments, current_environment: @environment)
      @modulepath ||= Puppet
      .settings
      .value(:modulepath, Parser::ENV_NAME, true)
      .split(File::PATH_SEPARATOR)
      .reject { |path| path.start_with? '$' }
      @modulepath.each do |path|
        info "Validating modulepath #{path}"
        unless Dir.exist? path
          warn "modulepath directory #{path} does not exist"
          exit 1
        end
      end
    end

    def list_dependencies
      raise "No dependencies defined! Did you run resolve?" if @dependencies.nil?
      puts @dependencies.join ' '
    end

    def generate_definitions
      FileUtils.mkdir_p(File.dirname(options(:definitions_file)))
      File.open(options(:definitions_file), 'w') do |file|
        file.truncate(0)
        file.write(JSON.fast_generate(@definitions))
      end
    end

    def load_known_warnings
      return unless File.exist? options(:known_warnings_file)
      info "Loading known warnings from #{options(:known_warnings_file)}"
      dsl = DSL.new(@known_warnings)
      begin
        contents = File.read(options(:known_warnings_file))
        dsl.instance_eval contents, options(:known_warnings_file)
      rescue ArgumentError => e
        STDERR.puts "Error while parsing known warnings: #{e}"
        exit 1
      end
    end

    def generate_known_warnings
      FileUtils.mkdir_p(File.dirname(options(:known_warnings_file)))
      File.open(options(:known_warnings_file), 'w') do |file|
        file.truncate(0)
        @found_warnings.each do |type, warnings|
          warnings.each do |warning|
            file.puts "#{type} #{WARNING_TYPES[type].map do |attr|
              "#{attr}: #{warning[attr].is_a?(Symbol) ? ":#{warning[attr]}" : "'#{warning[attr]}'"}"
            end.join(', ')}"
          end
        end
      end
    end

    def warning_known?(warning_type, *args)
      raise "Unknown warning type #{warning_type}" unless @known_warnings.key? warning_type
      warning = Hash.new
      WARNING_TYPES[warning_type].each_with_index do |attr, index|
        warning[attr] = args[index]
      end
      @found_warnings[warning_type] << warning
      return true if @known_warnings[warning_type].any? { |known| warning == known }
    end

    def options(option)
      raise "Unknown option #{option}" unless @options.key? option
      @options[option]
    end

    def collect_builtins
      return unless @builtin_types.empty?
      Puppet::Type.loadall
      Puppet::Type.eachtype do |type|
        @builtin_types << type
        add_definition :resource_type, type.name, 'builtin'
      end
      Puppet::Pops::Types::TypeParser.type_map.keys.map do |type|
        add_definition :type, type, 'builtin'
      end
      Puppet::Parser::Functions.autoloader.files_to_load.each do |file|
        name = File.basename(file, '.rb')
        add_definition :function_3x, name, 'builtin'
      end
      Puppet::Util::Autoload.new(Object.new, 'puppet/functions').files_to_load.each do |file|
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
      info "Setting module data for #{modname}: #{data}"
      @modules[modname] = data
    end

    def get_module_info(path)
      is_control_repo = File.exist?(File.join(path, 'Puppetfile'))
      name = if is_control_repo
               File.basename(path)
             elsif File.exist?(File.join(path, 'metadata.json')) \
               || File.exist?(File.join(path, 'manifests'))
               File.basename(path).sub(%r{^[^-]+-},'')
             end
      module_info = { name: name, path: path, is_control_repo: is_control_repo }
      info "Found module info #{module_info}"
      module_info
    end

    def add_definition(type, name, source = @current_module[:name], ignore_dup = false)
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
      name = name.to_s.sub(%r{^::}, '')
      raise "Invalid dependency type #{type}" unless source[:dependencies].key? type
      # Don't add builtin variables
      return if type == :variable && name.start_with?('settings::')
      source[:dependencies][type][name] ||= []
      source[:dependencies][type][name] << @current_file unless source[:dependencies][type][name].include? @current_file
    end

    def parse_file(file)
      debug "Parsing #{file}"
      @current_file = Pathname.new(file).relative_path_from(@envdir_pn).to_s
      @literal_strings = []
      @qualified_names = []
      results = @parser.parse_file(file)
      debug results.locator.string
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
      modules_to_scan = if !options(:scan_modules).empty?
                          options(:scan_modules)
                        elsif options(:restrict_scan)
                          options(:modules)
                        else
                          []
                        end
      info modules_to_scan.empty? ?
        "Scanning all modules" :
        "Found modules_to_scan #{modules_to_scan}"
      if (modules_to_scan.empty? && @envdir_info[:is_control_repo]) || modules_to_scan.include?(@envdir_info[:name])
        scan_module(@envdir_info)
      end
      @modulepath.each do |path|
        debug "Processing modulepath #{path}"
        Dir.entries(path).each do |name|
          debug "Processing modulepath file #{name}"
          next unless Puppet::Module.is_module_directory?(name, path)
          module_info = get_module_info(File.join(path, name))
          next unless modules_to_scan.empty? || modules_to_scan.include?(module_info[:name])
          if @modules.include? module_info[:name]
            info "Module #{module_info[:name]} already processed. Skipping"
            next
          end
          scan_module(module_info)
        end
      end
      unscanned_modules = modules_to_scan.empty? ? (options(:modules) - @modules.keys) : (modules_to_scan - @modules.keys)
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

    def scan_module(module_info)
      path = module_info[:path]
      unless module_info[:name]
        warn "#{path} doesn't appear to be a module directory. Skipping path."
        return
      end
      @current_module = module_info.merge({
        dependencies: Hash[DEPENDENCY_TYPES.map { |type| [type, {}] }],
      })
      @current_class = nil
      info "Scanning module #{@current_module[:name]} (#{path})"

      # Process .pp files
      pp_dirs = ['manifests', 'functions', 'types']
      pp_dirs.each do |dir|
        pattern = File.join(path, dir, '**', '*.pp')
        info "Searching Puppet #{dir} with pattern #{pattern}"
        Dir.glob(pattern) do |file|
          next if File.directory?(file)
          parse_file(file)
        end
      end

      plugindir = File.join(path, 'lib')

      # Process custom types
      pattern = File.join(plugindir, 'puppet', 'type', '*.rb')
      info "Loading ruby custom types with pattern #{pattern}"
      Dir.glob(pattern).each do |file|
        begin
          debug "Loading #{file}"
          Kernel.load file
        rescue => e
          raise "Failed to load #{file}: #{e.message} #{e.backtrace}"
        end
      end
      types = Puppet::Type.instance_variable_get(:@types).values - @builtin_types
      unless types.empty?
        info "Found custom types #{types.map { |type| type.name }.sort}"
      end
      types.each do |type|
        add_definition :resource_type, type.name
        Puppet::Type.rmtype(type.name)
      end

      $LOAD_PATH.unshift(plugindir)

      # Process 3x ruby functions
      pattern = File.join(plugindir, 'puppet', 'parser', 'functions', '*.rb')
      info "Loading ruby custom 3x functions with pattern #{pattern}"
      Dir.glob(pattern).each do |file|
        begin
          debug "Loading #{file}"
          Kernel.load file
        rescue => e
          raise "Failed to load #{file}: #{e.message} #{e.backtrace}"
        end
      end
      functions = Puppet::Parser::Functions.environment_module(@environment).all_function_info
      info "Found functions #{functions.keys.sort}"
      functions.each { |function, _| add_definition :function_3x, function }
      Puppet::Parser::Functions::AnonymousModuleAdapter.clear(@environment)

      # Process 4x ruby functions and datatypes
      info 'Loading ruby functions and datatypes'
      mod = Puppet::Module.new(@current_module[:name], path, @environment, true)
      @environment.instance_variable_set(:@modules, [mod])
      loader = Puppet::Pops::Loader::ModuleLoaders::FileBased.new(@loaders.static_loader, @loaders, mod.name, mod.path, mod.name, [:func_4x, :datatype])
      loader.private_loader = Puppet::Pops::Loader::DependencyLoader.new(loader, "#{mod.name} private", [loader])
      [:function, :type].each do |type|
        errors = []
        builtin = loader.parent.discover(type, errors)
        results = loader.discover(type, errors)
        diff = results - builtin
        errors.each do |error|
          warn "Found #{type} error #{error}" unless warning_known? :type_error, type, error, source
        end
        info "Found #{type}s #{diff.map { |result| result.name }}" unless diff.empty?
        diff.each { |result| add_definition type, result.name }
      end

      $LOAD_PATH.delete(plugindir)

      set_module(mod.name, @current_module)
    end

    def resolve
      raise 'No parsed modules found! Did you run `rake spec_prep` or `pdk test unit` first?' if @modules.empty?
      info 'Resolving module dependencies'
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
      modules_to_resolve = options(:modules).empty? ? @modules : @modules.select { |name, _mod| options(:modules).include? name }
      resolved_modules = []
      until modules_to_resolve.empty?
        name, mod = modules_to_resolve.shift
        info "Resolving module #{name}"
        module_deps = []
        mod[:dependencies].each do |type, dependency_list|
          dependency_list.each do |dependency, sources|
            found = false
            if @definitions[type].include? dependency
              module_deps << @definitions[type][dependency]
              found = true
            elsif type == :type
              if @definitions[:resource_type].include? dependency
                module_deps << @definitions[:resource_type][dependency]
                found = true
              elsif @definitions[:type_alias].include? dependency
                module_deps << @definitions[:type_alias][dependency]
                found = true
              end
            elsif type == :resource_type
              if @definitions[:type].include? dependency
                module_deps << @definitions[:type][dependency]
                found = true
              end
            elsif type == :function
              if @definitions[:function_3x].include? dependency
                module_deps << @definitions[:function_3x][dependency]
                found = true
              end
            end
            next if found
            unknown_warning_sources = sources.reject { |source| warning_known? :missing_definition, type, dependency, source }
            next if unknown_warning_sources.empty?
            warn "Failed to find #{type} #{dependency}. Sources #{unknown_warning_sources.join(', ')}"
          end
        end
        # Remove self and builtin
        module_deps = (module_deps - ['builtin', name]).sort.uniq
        unless CONTROL_MODULES.include?(name) || mod[:is_control_repo]
          CONTROL_MODULES.each do |control_module|
            next unless module_deps.include? control_module
            next if warning_known? :control_dependency, name
            warn "WARNING: Module #{name} depends on control repo module '#{control_module}'"
          end
        end
        info "Found #{name} dependencies #{module_deps}"
        resolved_modules << name
        if options(:recurse)
          module_deps.each do |dep|
            unless CONTROL_MODULES.include?(dep) || resolved_modules.include?(dep)
              modules_to_resolve[dep] = get_module(dep)
            end
          end
        end
        dependencies += module_deps
      end
      @dependencies = dependencies.sort.uniq
    end

    # rubocop:disable Metrics/BlockNesting
    def process_result(result, parents = [], indent = 0)
      debug_write "%#{indent}sFound %s" % ['', result.class]
      begin
        case result
        when Puppet::Pops::Model::Parameter
          debug_write " '#{result.name}'"
        when Puppet::Pops::Model::LiteralInteger
          debug_write " '#{result.value}'"
        when Puppet::Pops::Model::RelationshipExpression
          debug_write " '#{result.operator}'"
        when Puppet::Pops::Model::MatchExpression
          debug_write " '#{result.operator}'"
        when Puppet::Pops::Model::LiteralBoolean
          debug_write " '#{result.value}'"
        when Puppet::Pops::Model::LiteralRegularExpression
          debug_write " '#{result.pattern}'"
        when Puppet::Pops::Model::ArithmeticExpression
          debug_write " '#{result.operator}'"
        when Puppet::Pops::Model::AttributeOperation
          debug_write " '#{result.attribute_name}'"
        when Puppet::Pops::Model::LiteralDefault
          debug_write ' <default>'
        when Puppet::Pops::Model::LiteralUndef
          debug_write ' <undef>'
        when Puppet::Pops::Model::Nop
          debug_write ' <noop>'
        when Puppet::Pops::Model::LiteralString
          debug_write " '#{result.value}'"
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
            debug_write ' UNRESOLVED' unless @literal_strings.reject! { |name| name.object_id == result.object_id }
          end
        when Puppet::Pops::Model::QualifiedName
          debug_write " '#{result.value}'"
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
            debug_write ' UNRESOLVED' unless @qualified_names.reject! { |name| name.object_id == result.object_id }
          end
        when Puppet::Pops::Model::HostClassDefinition
          debug_write " '#{result.name}'"
          add_definition :class, result.name.downcase
          @current_class = result.name
          result.parameters.each do |parameter|
            add_definition :variable, [@current_class, parameter.name.downcase].join('::')
          end
          unless result.parent_class.nil?
            debug_write " (inherits #{result.parent_class})"
            @inherits[result.name] = result.parent_class
          end
        when Puppet::Pops::Model::QualifiedReference
          debug_write " '#{result.cased_value}'"
          add_dependency :type, result.value
        when Puppet::Pops::Model::TypeAlias
          debug_write " #{result.name}"
          add_definition :type_alias, result.name.downcase
        when Puppet::Pops::Model::FunctionDefinition
          debug_write " #{result.name}"
          add_definition :function, result.name
        when Puppet::Pops::Model::ResourceTypeDefinition
          debug_write " #{result.name}"
          add_definition :resource_type, result.name
        when Puppet::Pops::Model::AssignmentExpression
          unless result.left_expr.class == Puppet::Pops::Model::VariableExpression
            raise "Unknown AssignmentExpression left_expr #{result.left_expr.class}"
          end
          case result.left_expr.expr
          when Puppet::Pops::Model::QualifiedName
            unless @current_class.nil?
              add_definition :variable, [@current_class, result.left_expr.expr.value].join('::'), @current_module[:name], true
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
            debug_write " '#{result.type_name.value}' (#{result.form})"
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
            debug_write " '#{result.functor_expr.value}'"
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
            debug_write " '#{result.functor_expr.value}'"
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
            debug_write ' UNRESOLVED'
          end
        end
        # debug_write @dumper.dump(result)
        debug_write "\n"
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
  end
end
