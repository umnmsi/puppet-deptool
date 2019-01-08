module PuppetDeptool
  module Consts
    DEPENDENCY_TYPES = [:class, :function, :type, :resource_type, :variable].freeze
    DEFINITION_TYPES = [:class, :function, :function_3x, :type, :resource_type, :variable, :type_alias].freeze
    WARNING_TYPES = {
      duplicate_definition: [:type, :name, :source],
      missing_definition:   [:type, :name, :source],
      type_error:           [:name, :error, :source],
      control_dependency:   [:name],
    }.freeze
    CONTROL_MODULES = ['role', 'profile'].freeze
    ENV_NAME = :parser
  end
end
