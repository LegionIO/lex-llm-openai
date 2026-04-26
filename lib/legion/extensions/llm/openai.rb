# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/openai/provider_settings'
require 'legion/extensions/llm/openai/version'

module Legion
  module Extensions
    module Llm
      # Openai provider extension namespace.
      module Openai
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :openai

        def self.default_settings
          ProviderSettings.build(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://api.openai.com',
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://OPENAI_API_KEY' },
              usage: { inference: true, embedding: true },
              limits: { concurrency: 4 }
            }
          )
        end
      end
    end
  end
end
