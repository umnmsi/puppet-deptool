Gem::Specification.new do |s|
  s.name = 'puppet-deptool'
  s.version = '0.1.0'
  s.authors = ['Nick Bertrand']
  s.summary = 'Tool for working with puppet control repo and module dependencies'
  s.executables = ['check_dependencies', 'check_environments']
  s.add_runtime_dependency 'r10k'
end
