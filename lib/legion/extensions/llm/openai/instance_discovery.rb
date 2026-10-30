# frozen_string_literal: true

require 'legion/extensions/llm/openai/chatgpt/auth'

module Legion
  module Extensions
    module Llm
      module Openai
        # Read-only API-key and native subscription candidates. Credential-less
        # and disabled instances are never claimed; subscription identity comes
        # from the operator's named Legion login, not a token fingerprint.
        module InstanceDiscovery
          extend Legion::Logging::Helper

          CHATGPT_IDENTITY_FIELDS = %i[instance_id account_id workspace_id].freeze

          module_function

          def discover
            candidates = {}
            collect_env_key_candidates(candidates)
            collect_codex_candidates(candidates)
            collect_settings_candidates(candidates)
            collect_chatgpt_candidates(candidates)
            dedup_and_log_candidates(candidates)
          end

          def collect_env_key_candidates(candidates)
            env_key = CredentialSources.env('OPENAI_API_KEY')
            candidates[:env] = { api_key: env_key, openai_api_key: env_key, tier: :frontier } if env_key
            codex_env = CredentialSources.env('CODEX_API_KEY')
            candidates[:codex_env] = { api_key: codex_env, openai_api_key: codex_env, tier: :frontier } if codex_env
          end

          def collect_codex_candidates(candidates)
            codex_key = CredentialSources.codex_openai_key
            candidates[:codex_key] = { api_key: codex_key, openai_api_key: codex_key, tier: :frontier } if codex_key
            claude_key = CredentialSources.claude_config_value(:openaiApiKey)
            candidates[:claude] = { api_key: claude_key, openai_api_key: claude_key, tier: :frontier } if claude_key
          end

          def collect_chatgpt_candidates(candidates)
            Legion::Extensions::Llm::Openai::Chatgpt::Auth.instances.each do |name, record|
              key = name.to_sym
              configured = candidates[key]
              next if configured && configured[:enabled] == false

              native = {
                auth_mode: :chatgpt, instance_id: name.to_s,
                account_id: record.fetch(:account_id), workspace_id: record[:workspace_id],
                auth_status: record.fetch(:status).to_sym, tier: :frontier
              }
              validate_chatgpt_configuration!(configured: configured, native: native)
              candidates[key] = (configured || {}).merge(native)
            end
          end

          def validate_chatgpt_configuration!(configured:, native:)
            return if configured.nil?
            raise ArgumentError, 'An OpenAI API-key instance conflicts with a named ChatGPT login' unless
              configured[:auth_mode] == :chatgpt

            CHATGPT_IDENTITY_FIELDS.each do |field|
              next unless configured.key?(field) && configured[field] != native[field]

              raise ArgumentError, 'Configured ChatGPT identity conflicts with the native login'
            end
          end

          def collect_settings_candidates(candidates)
            settings_config = CredentialSources.setting(:extensions, :llm, :openai)
            add_settings_key_candidate(candidates, settings_config)
            add_named_instance_candidates(candidates, settings_config)
          end

          def add_settings_key_candidate(candidates, settings_config)
            return unless settings_config.is_a?(Hash) && !settings_config.empty?

            settings_key = settings_config[:api_key] || settings_config['api_key']
            return unless settings_key

            candidates[:settings] = normalize_instance_config(settings_config).merge(
              api_key: settings_key, openai_api_key: settings_key, tier: :frontier
            )
          end

          def add_named_instance_candidates(candidates, settings_config)
            settings_instances(settings_config).each do |name, config|
              next unless config.is_a?(Hash)

              normalized = normalize_instance_config(config)
              validate_instance_name!(name: name, config: normalized)

              normalized[:instance_id] = name.to_s
              dedup_key = normalized[:openai_api_key]
              normalized[:api_key] = dedup_key if dedup_key
              candidates[name.to_sym] = normalized.merge(tier: :frontier)
            end
          end

          def validate_instance_name!(name:, config:)
            return unless config.key?(:instance_id) && config[:instance_id].to_s != name.to_s

            raise ArgumentError, 'OpenAI instance identity must match its configured name'
          end

          def dedup_and_log_candidates(candidates)
            deduped = CredentialSources.dedup_credentials(candidates)
            discovered = deduped.reject { |_, config| config[:enabled] == false || unresolved_credential?(config) }
                                .transform_values { |cfg| sanitize_instance_config(cfg) }
            instance_names = discovered.keys.sort_by(&:to_s).join(', ')
            log.debug { "Discovered #{discovered.size} OpenAI provider instance candidate(s): #{instance_names}" }
            discovered
          end

          # enabled: false is a skip, not a credential: a disabled instance is
          # never claimed (the discovery pipeline reads this method as the
          # single claimable source). A nil credential or an unresolved
          # env:// / vault:// placeholder (the synthetic provider_settings
          # default nests env://OPENAI_API_KEY) cannot authenticate and is
          # never claimed.
          def unresolved_credential?(config)
            if config[:auth_mode] == :chatgpt
              return config[:account_id].nil? || config[:auth_status] == :reauth_required
            end

            cred = config[:openai_api_key]
            cred.nil? || cred.to_s.match?(%r{\A(vault|env)://})
          end

          def settings_instances(config)
            return {} unless config.is_a?(Hash)

            instances = config[:instances] || config['instances']
            instances.is_a?(Hash) ? instances : {}
          end

          def normalize_instance_config(config)
            normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            normalize_openai_aliases(normalized)
            mode = normalized.fetch(:auth_mode, :api_key).to_s
            raise ArgumentError, 'Unsupported OpenAI authentication mode' unless %w[api_key chatgpt].include?(mode)

            normalized[:auth_mode] = mode.to_sym
            validate_chatgpt_credentials!(config: normalized) if normalized[:auth_mode] == :chatgpt

            normalized.compact.except(:instances)
          end

          def validate_chatgpt_credentials!(config:)
            tokens = %i[openai_api_key access_token refresh_token bearer_token]
            return unless tokens.any? { |key| config[key] } || (config[:credentials] && config[:credentials] != {})

            raise ArgumentError, 'ChatGPT instances use native login records, not configured credentials'
          end

          def normalize_openai_aliases(normalized)
            {
              openai_api_key: %i[api_key],
              openai_api_base: %i[base_url api_base endpoint],
              openai_organization_id: %i[organization_id],
              openai_project_id: %i[project_id]
            }.each do |target, sources|
              sources.each { |src| normalized[target] ||= normalized.delete(src) }
            end
          end

          def sanitize_instance_config(config)
            config.except(:api_key, :organization_id, :project_id)
          end
        end
      end
    end
  end
end
