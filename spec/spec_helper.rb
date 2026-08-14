# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/extensions/llm'

Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false)

require 'legion/extensions/llm/openai'

# Load the conformance kit from the installed lex-llm gem.
# Per B1b consumer pattern: spec/ ships in lex-llm but is NOT on load path.
begin
  require 'rspec'

  kit_path = File.join(
    Gem.loaded_specs['lex-llm'].full_gem_path,
    'spec/legion/extensions/llm/conformance'
  )
  Dir[File.join(kit_path, '**', '*.rb')].each { |f| require f }
  Legion::Logging.debug { "Conformance kit loaded from #{kit_path}" }
rescue Gem::LoadError, StandardError => e
  Legion::Logging.warn("[spec_helper] conformance kit not available: #{e.message}")
end

# §9: Inject routing[:model] into conformance request fixtures so the translator
# always receives a model. The conformance kit fixtures predate the §9 rule that
# routing must carry a model; patching here keeps the kit unchanged.
if defined?(Canonical::Conformance)
  module Canonical
    module Conformance
      class << self
        alias fixture_without_model_injection fixture

        def fixture(name)
          data = fixture_without_model_injection(name)
          data['routing'] = { 'model' => 'gpt-4o-mini' } if name.end_with?('_request') && !data.key?('routing')
          data
        end
      end
    end
  end
end
