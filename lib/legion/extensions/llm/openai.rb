# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/openai/provider'
require 'legion/extensions/llm/openai/translator'
require 'legion/extensions/llm/openai/version'
require_relative 'openai/actors/discovery_refresh'

module Legion
  module Extensions
    module Llm
      # Openai provider extension namespace.
      module Openai
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend ::Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :openai
        # Provider's preferred default when the operator configures none. Used only
        # as a fallback and only when the configured model policy permits it
        # (see resolve_default_model) — a whitelist/blacklist is never overridden.
        DEFAULT_MODEL = 'gpt-5.5'

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://api.openai.com',
              default_model: DEFAULT_MODEL,
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
        end

        def self.provider_class
          Provider
        end

        def self.discover_instances # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          log.debug('Discovering OpenAI provider instances')
          candidates = {}

          # 1. OPENAI_API_KEY environment variable
          env_key = CredentialSources.env('OPENAI_API_KEY')
          candidates[:env] = { api_key: env_key, openai_api_key: env_key, tier: :frontier } if env_key

          # 2. CODEX_API_KEY environment variable
          codex_env_key = CredentialSources.env('CODEX_API_KEY')
          if codex_env_key
            candidates[:codex_env] = { api_key: codex_env_key, openai_api_key: codex_env_key, tier: :frontier }
          end

          # 3. Codex bearer token (~/.codex/auth.json chatgpt mode)
          codex_tok = CredentialSources.codex_token
          candidates[:codex] = { api_key: codex_tok, openai_api_key: codex_tok, tier: :frontier } if codex_tok

          # 4. Codex OPENAI_API_KEY from ~/.codex/auth.json
          codex_key = CredentialSources.codex_openai_key
          candidates[:codex_key] = { api_key: codex_key, openai_api_key: codex_key, tier: :frontier } if codex_key

          # 5. Claude config openaiApiKey
          claude_key = CredentialSources.claude_config_value(:openaiApiKey)
          candidates[:claude] = { api_key: claude_key, openai_api_key: claude_key, tier: :frontier } if claude_key

          # 6. Extension settings
          settings_config = CredentialSources.setting(:extensions, :llm, :openai)
          if settings_config.is_a?(Hash) && !settings_config.empty?
            settings_key = settings_config[:api_key] || settings_config['api_key']
            if settings_key
              candidates[:settings] = normalize_instance_config(settings_config).merge(
                api_key: settings_key,
                openai_api_key: settings_key,
                tier: :frontier
              )
            end
          end

          # 7. Named provider instances from extension settings
          settings_instances(settings_config).each do |name, config|
            next unless config.is_a?(Hash)

            normalized = normalize_instance_config(config)
            dedup_key = normalized[:openai_api_key]
            normalized[:api_key] = dedup_key if dedup_key
            candidates[name.to_sym] = normalized.merge(tier: :frontier)
          end

          # 8. Dedup + inject a policy-aware default_model
          discovered = CredentialSources.dedup_credentials(candidates).transform_values do |config|
            sanitized = sanitize_instance_config(config)
            sanitized[:default_model] = resolve_default_model(sanitized)
            sanitized
          end
          instance_names = discovered.keys.sort_by(&:to_s).join(', ')
          log.debug { "Discovered #{discovered.size} OpenAI provider instance candidate(s): #{instance_names}" }
          discovered
        end

        # Resolve a default_model that never violates the configured model policy
        # (whitelist/blacklist stays authoritative over the DEFAULT_MODEL fallback).
        def self.resolve_default_model(config)
          provider_class.policy_safe_default_model(
            configured: config[:default_model], fallback: DEFAULT_MODEL,
            **provider_class.model_policy(config, PROVIDER_FAMILY)
          )
        end

        def self.settings_instances(config)
          return {} unless config.is_a?(Hash)

          instances = config[:instances] || config['instances']
          instances.is_a?(Hash) ? instances : {}
        end

        def self.normalize_instance_config(config) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:openai_api_key] ||= normalized.delete(:api_key)
          normalized[:openai_api_base] ||= normalized.delete(:base_url)
          normalized[:openai_api_base] ||= normalized.delete(:api_base)
          normalized[:openai_api_base] ||= normalized.delete(:endpoint)
          normalized[:openai_organization_id] ||= normalized.delete(:organization_id)
          normalized[:openai_project_id] ||= normalized.delete(:project_id)
          normalized.compact.except(:instances)
        end

        def self.sanitize_instance_config(config)
          config.except(:api_key, :organization_id, :project_id)
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
