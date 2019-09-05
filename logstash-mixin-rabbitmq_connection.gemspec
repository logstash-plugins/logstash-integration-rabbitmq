
Gem::Specification.new do |s|
  s.name            = 'logstash-mixin-rabbitmq_connection'
  s.version         = '5.1.0'
  s.licenses        = ['Apache License (2.0)']
  s.summary         = "Common functionality for RabbitMQ plugins"
  s.description     = "This gem is a Logstash plugin required to be installed on top of the Logstash core pipeline using $LS_HOME/bin/logstash-plugin install gemname. This gem is not a stand-alone program"
  s.authors         = ["Elastic"]
  s.email           = 'info@elastic.co'
  s.homepage        = "http://www.elastic.co/guide/en/logstash/current/index.html"
  s.require_paths = ["lib"]

  # Files
  s.files = `git ls-files`.split($\)+::Dir.glob('vendor/*')

  # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  s.platform = RUBY_PLATFORM

  # MarchHare 3.x+ includes ruby syntax from 2.x
  # This effectively requires Logstash >= 6.x
  s.required_ruby_version = '>= 2.0.0'

  s.add_runtime_dependency 'march_hare', ['~> 4.0'] #(MIT license)
  s.add_runtime_dependency 'stud', '~> 0.0.22'

  s.add_development_dependency 'logstash-devutils'
  s.add_development_dependency 'logstash-input-generator'
  s.add_development_dependency 'logstash-codec-json'
end
