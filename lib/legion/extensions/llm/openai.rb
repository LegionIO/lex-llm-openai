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
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :openai

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://api.openai.com',
              default_model: 'gpt-4o',
              tier: :frontier,
              transport: :http,
              credentials: {
                api_key: 'env://OPENAI_API_KEY',
                organization_id: nil,
                project_id: nil
              },
              usage: { inference: true, embedding: true, image: true },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed image],
                lanes: [],
                concurrency: 4,
                queue_suffix: nil
              }
            }
          )
        end

        def self.provider_class
          Provider
        end

        def self.discover_instances # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          candidates = {}

          # 1. OPENAI_API_KEY environment variable
          env_key = CredentialSources.env('OPENAI_API_KEY')
          candidates[:env] = { openai_api_key: env_key, tier: :frontier } if env_key

          # 2. CODEX_API_KEY environment variable
          codex_env_key = CredentialSources.env('CODEX_API_KEY')
          candidates[:codex_env] = { openai_api_key: codex_env_key, tier: :frontier } if codex_env_key

          # 3. Codex bearer token (~/.codex/auth.json chatgpt mode)
          codex_tok = CredentialSources.codex_token
          candidates[:codex] = { openai_api_key: codex_tok, tier: :frontier } if codex_tok

          # 4. Codex OPENAI_API_KEY from ~/.codex/auth.json
          codex_key = CredentialSources.codex_openai_key
          candidates[:codex_key] = { openai_api_key: codex_key, tier: :frontier } if codex_key

          # 5. Claude config openaiApiKey
          claude_key = CredentialSources.claude_config_value(:openaiApiKey)
          candidates[:claude] = { openai_api_key: claude_key, tier: :frontier } if claude_key

          # 6. Extension settings
          settings_config = CredentialSources.setting(:extensions, :llm, :openai)
          if settings_config.is_a?(Hash) && !settings_config.empty?
            settings_key = settings_config[:api_key] || settings_config['api_key']
            if settings_key
              candidates[:settings] = normalize_instance_config(settings_config).merge(
                openai_api_key: settings_key,
                tier: :frontier
              )
            end
          end

          # 7. Named provider instances from extension settings
          settings_instances(settings_config).each do |name, config|
            next unless config.is_a?(Hash)

            candidates[name.to_sym] = normalize_instance_config(config).merge(tier: :frontier)
          end

          # 8. Dedup
          CredentialSources.dedup_credentials(candidates)
        end

        def self.settings_instances(config)
          return {} unless config.is_a?(Hash)

          instances = config[:instances] || config['instances']
          instances.is_a?(Hash) ? instances : {}
        end

        def self.normalize_instance_config(config) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:openai_api_key] ||= normalized[:api_key]
          normalized[:openai_api_base] ||= normalized.delete(:base_url)
          normalized[:openai_api_base] ||= normalized.delete(:api_base)
          normalized[:openai_api_base] ||= normalized.delete(:endpoint)
          normalized[:openai_organization_id] ||= normalized[:organization_id]
          normalized[:openai_project_id] ||= normalized[:project_id]
          normalized.compact.except(:instances)
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options) if
          Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
      end
    end
  end
end

Legion::Extensions::Llm::Openai.register_discovered_instances
