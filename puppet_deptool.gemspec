# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name = 'puppet_deptool'
  s.version = '0.1.0'
  s.required_ruby_version = '>= 2.7.0'
  s.authors = ['Nick Bertrand']
  s.summary = 'Tool for working with puppet control repo and module dependencies'
  s.executables = %w[update_fixtures check_dependencies check_environments]
  s.add_dependency 'ffi'
  s.add_dependency 'generate-puppetfile'
  s.add_dependency 'openvox'
  s.add_dependency 'r10k'
  s.add_dependency 'syslog'
  s.metadata['rubygems_mfa_required'] = 'true'
end
