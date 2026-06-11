# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/extensions/llm'

Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false)

# register_provider_options is defined in the full runtime but not in the
# standalone Configuration class shipped with lex-llm.  Patch it in so the
# provider file can register its config options during require.
unless Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
  Legion::Extensions::Llm::Configuration.define_singleton_method(:register_provider_options) do |keys|
    Array(keys).each { |k| option(k) }
  end
end

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
