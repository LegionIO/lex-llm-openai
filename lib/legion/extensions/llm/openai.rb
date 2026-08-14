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
        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
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
        end

        def self.provider_class
          Provider
        end

        def self.discover_instances
          log.debug('Discovering OpenAI provider instances')
          candidates = {}
          collect_env_key_candidates(candidates)
          collect_codex_candidates(candidates)
          collect_settings_candidates(candidates)
          dedup_and_log_candidates(candidates)
        end

        def self.collect_env_key_candidates(candidates)
          env_key = CredentialSources.env('OPENAI_API_KEY')
          candidates[:env] = { api_key: env_key, openai_api_key: env_key, tier: :frontier } if env_key
          codex_env = CredentialSources.env('CODEX_API_KEY')
          candidates[:codex_env] = { api_key: codex_env, openai_api_key: codex_env, tier: :frontier } if codex_env
        end

        def self.collect_codex_candidates(candidates)
          codex_tok = CredentialSources.codex_token
          candidates[:codex] = { api_key: codex_tok, openai_api_key: codex_tok, tier: :frontier } if codex_tok
          codex_key = CredentialSources.codex_openai_key
          candidates[:codex_key] = { api_key: codex_key, openai_api_key: codex_key, tier: :frontier } if codex_key
          claude_key = CredentialSources.claude_config_value(:openaiApiKey)
          candidates[:claude] = { api_key: claude_key, openai_api_key: claude_key, tier: :frontier } if claude_key
        end

        def self.collect_settings_candidates(candidates)
          settings_config = CredentialSources.setting(:extensions, :llm, :openai)
          add_settings_key_candidate(candidates, settings_config)
          add_named_instance_candidates(candidates, settings_config)
        end

        def self.add_settings_key_candidate(candidates, settings_config)
          return unless settings_config.is_a?(Hash) && !settings_config.empty?

          settings_key = settings_config[:api_key] || settings_config['api_key']
          return unless settings_key

          candidates[:settings] = normalize_instance_config(settings_config).merge(
            api_key: settings_key, openai_api_key: settings_key, tier: :frontier
          )
        end

        def self.add_named_instance_candidates(candidates, settings_config)
          settings_instances(settings_config).each do |name, config|
            next unless config.is_a?(Hash)

            normalized = normalize_instance_config(config)
            dedup_key = normalized[:openai_api_key]
            normalized[:api_key] = dedup_key if dedup_key
            candidates[name.to_sym] = normalized.merge(tier: :frontier)
          end
        end

        def self.dedup_and_log_candidates(candidates)
          discovered = CredentialSources.dedup_credentials(candidates)
                                        .transform_values { |cfg| sanitize_instance_config(cfg) }
          instance_names = discovered.keys.sort_by(&:to_s).join(', ')
          log.debug { "Discovered #{discovered.size} OpenAI provider instance candidate(s): #{instance_names}" }
          discovered
        end

        def self.settings_instances(config)
          return {} unless config.is_a?(Hash)

          instances = config[:instances] || config['instances']
          instances.is_a?(Hash) ? instances : {}
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalize_openai_aliases(normalized)
          normalized.compact.except(:instances)
        end

        def self.normalize_openai_aliases(normalized)
          {
            openai_api_key: %i[api_key],
            openai_api_base: %i[base_url api_base endpoint],
            openai_organization_id: %i[organization_id],
            openai_project_id: %i[project_id]
          }.each do |target, sources|
            sources.each { |src| normalized[target] ||= normalized.delete(src) }
          end
        end

        def self.sanitize_instance_config(config)
          config.except(:api_key, :organization_id, :project_id)
        end
        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
