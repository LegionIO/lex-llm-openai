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
              candidates[:settings] = settings_config.merge(
                openai_api_key: settings_key,
                tier: :frontier
              )
            end
          end

          # 7. Gateway instances from extension settings
          gateways = CredentialSources.setting(:extensions, :llm, :openai, :gateways)
          if gateways.is_a?(Hash)
            gateways.each do |name, config|
              next unless config.is_a?(Hash)

              candidates[name.to_sym] = config.merge(tier: :openai_compat)
            end
          end

          # 8. Dedup
          CredentialSources.dedup_credentials(candidates)
        end
      end
    end
  end
end

Legion::Extensions::Llm::Openai.register_discovered_instances
