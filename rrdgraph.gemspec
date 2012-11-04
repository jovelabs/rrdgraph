# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'rrdgraph/version'

Gem::Specification.new do |gem|
  gem.name          = "rrdgraph"
  gem.version       = RRDGraph::VERSION
  gem.authors       = ["Zachary Patten"]
  gem.email         = ["zachary@jovelabs.net"]
  gem.description   = %q{RRD Graph}
  gem.summary       = %q{Inheritable class to create custom RRD graphs from text logs easily}
  gem.homepage      = "https://github.com/jovelabs/rrdgraph"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_dependency("ztk")
end
