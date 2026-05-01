# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/openai/provider'
require 'legion/extensions/llm/openai/version'

module Legion
  module Extensions
    module Llm
      # Openai provider extension namespace.
      module Openai
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend ::Legion::Logging::Helper

        PROVIDER_FAMILY = :openai

        def self.default_settings
          {
            enabled: false,
            default_model: 'gpt-4o',
            api_key: nil,
            organization_id: nil,
            project_id: nil,
            model_whitelist: [],
            model_blacklist: [],
            model_cache_ttl: 3600,
            tls: { enabled: false, verify: :peer },
            instances: {}
          }
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end
