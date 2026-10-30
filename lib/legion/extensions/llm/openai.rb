# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/openai/provider'
require 'legion/extensions/llm/openai/translator'
require 'legion/extensions/llm/openai/chatgpt/auth'
require 'legion/extensions/llm/openai/chatgpt/provider'
require 'legion/extensions/llm/openai/instance_discovery'
require 'legion/extensions/llm/openai/version'
require 'legion/extensions/llm/openai/actors/discovery'

module Legion
  module Extensions
    module Llm
      # Openai provider extension namespace.
      module Openai
        extend ::Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :openai

        def self.default_settings
          base = ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              auth_mode: :api_key,
              endpoint: 'https://api.openai.com',
              tier: :frontier,
              transport: :http,
              credentials: {
                api_key: 'env://OPENAI_API_KEY',
                organization_id: nil,
                project_id: nil
              },
              usage: {
                inference: true,
                embedding: true,
                moderation: true,
                image: true,
                audio: true
              },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed image]
              }
            }
          )
          base.merge(chatgpt: { client_id: 'app_EMoamEEZ73f0CkXaXp7hrann' })
        end

        def self.provider_class
          Provider
        end

        def self.discover_instances
          log.debug { 'Discovering OpenAI provider instances' }
          InstanceDiscovery.discover
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
