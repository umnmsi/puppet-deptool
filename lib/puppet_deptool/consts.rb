# frozen_string_literal: true

module PuppetDeptool
  module Consts
    DEFAULT_ENVIRONMENT = 'persistent_systems_develop'
    # :type is a QualifiedReference that can refer to a datatype, defined type, resource type, or type alias
    DEPENDENCY_TYPES = %i[class function type provider resource_type variable].freeze
    DEFINITION_TYPES = %i[class function function_3x datatype provider defined_type resource_type
                          variable type_alias].freeze
    WARNING_TYPES = {
      duplicate_definition: %i[type name source],
      missing_definition: %i[type name source],
      type_error: %i[name error source],
      control_dependency: [:name],
      missing_metadata: [:name]
    }.freeze
    CONTROL_MODULES = %w[role profile].freeze
    ENV_NAME = :parser
    MODULE_NAME_PATTERN = %r{^([^-]+)[-/](.+)$}.freeze
    GITHUB_BASE_URL = 'https://github.umn.edu/api/v3'
    R10K_CONFIG_REPO = 'git@github.umn.edu:MSI-Puppet/r10k_config.git'
    DEPTOOL_DIR = '.deptool'
    GLOBAL_DEPTOOL_DIR = File.join(Dir.home, DEPTOOL_DIR).freeze
    DEPTOOL_CACHE = File.join(GLOBAL_DEPTOOL_DIR, 'cache').freeze
    GLOBAL_DEFAULTS = {
      verbose: 2
    }.freeze
  end
end
