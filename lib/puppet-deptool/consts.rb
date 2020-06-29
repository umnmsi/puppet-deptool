module PuppetDeptool
  module Consts
    DEFAULT_ENVIRONMENT = 'persistent_systems_develop'.freeze
    # :type is a QualifiedReference that can refer to a datatype, defined type, resource type, or type alias
    DEPENDENCY_TYPES = [:class, :function, :type, :provider, :resource_type, :variable].freeze
    DEFINITION_TYPES = [:class, :function, :function_3x, :datatype, :provider, :defined_type, :resource_type, :variable, :type_alias].freeze
    WARNING_TYPES = {
      duplicate_definition: [:type, :name, :source],
      missing_definition:   [:type, :name, :source],
      type_error:           [:name, :error, :source],
      control_dependency:   [:name],
      missing_metadata:     [:name],
    }.freeze
    CONTROL_MODULES = ['role', 'profile'].freeze
    ENV_NAME = :parser
    MODULE_NAME_PATTERN = %r{^([^-]+)[-/](.+)$}
    GITHUB_BASE_URL = 'https://github.umn.edu/api/v3'.freeze
    R10K_CONFIG_REPO = 'git@github.umn.edu:MSI-Puppet/r10k_config.git'.freeze
    DEPTOOL_DIR = '.deptool'.freeze
    GLOBAL_DEPTOOL_DIR = File.join(ENV['HOME'], DEPTOOL_DIR).freeze
    DEPTOOL_CACHE = File.join(GLOBAL_DEPTOOL_DIR, 'cache').freeze
    GLOBAL_DEFAULTS = {
      verbose: 2,
    }.freeze
  end
end
