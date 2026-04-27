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

        PROVIDER_FAMILY = :openai

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://api.openai.com',
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://OPENAI_API_KEY' },
              usage: { inference: true, embedding: true, moderation: true, image: true, audio: true },
              limits: { concurrency: 4 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

LexLLM::Provider.register(Legion::Extensions::Llm::Openai::PROVIDER_FAMILY,
                          Legion::Extensions::Llm::Openai::Provider)
