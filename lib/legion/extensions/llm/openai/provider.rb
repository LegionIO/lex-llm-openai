# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Openai
        # OpenAI provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          include Legion::Logging::Helper

          # ── Static capability map for known OpenAI model families ──────
          # Maps model-id prefixes to a set of capabilities and modality
          # vectors. Used by list_models to build Model::Info structs from
          # the raw /v1/models response.
          CAPABILITY_MAP = {
            'gpt-4o' => {
              capabilities: %i[completion streaming function_calling tools vision structured_output],
              modalities_input: %w[text image audio],
              modalities_output: %w[text],
              context_window: 128_000
            },
            'gpt-4.1' => {
              capabilities: %i[completion streaming function_calling tools vision structured_output],
              modalities_input: %w[text image],
              modalities_output: %w[text],
              context_window: 1_047_576
            },
            'gpt-4' => {
              capabilities: %i[completion streaming function_calling tools vision],
              modalities_input: %w[text image],
              modalities_output: %w[text],
              context_window: 128_000
            },
            'gpt-5' => {
              capabilities: %i[completion streaming function_calling tools vision structured_output reasoning],
              modalities_input: %w[text image],
              modalities_output: %w[text],
              context_window: 1_047_576
            },
            'o4' => {
              capabilities: %i[completion streaming function_calling tools vision reasoning],
              modalities_input: %w[text image],
              modalities_output: %w[text],
              context_window: 200_000
            },
            'o3' => {
              capabilities: %i[completion streaming function_calling tools vision reasoning],
              modalities_input: %w[text image],
              modalities_output: %w[text],
              context_window: 200_000
            },
            'o1' => {
              capabilities: %i[completion streaming function_calling tools vision reasoning],
              modalities_input: %w[text image],
              modalities_output: %w[text],
              context_window: 200_000
            },
            'text-embedding-' => {
              capabilities: %i[embedding],
              modalities_input: %w[text],
              modalities_output: %w[embeddings],
              context_window: 8_191
            },
            'omni-moderation' => {
              capabilities: %i[moderation],
              modalities_input: %w[text image],
              modalities_output: %w[moderation]
            },
            'text-moderation' => {
              capabilities: %i[moderation],
              modalities_input: %w[text],
              modalities_output: %w[moderation]
            },
            'gpt-image' => {
              capabilities: %i[image_generation],
              modalities_input: %w[text image],
              modalities_output: %w[image]
            },
            'dall-e' => {
              capabilities: %i[image_generation],
              modalities_input: %w[text],
              modalities_output: %w[image]
            },
            'whisper' => {
              capabilities: %i[audio_transcription],
              modalities_input: %w[audio],
              modalities_output: %w[text]
            },
            'tts' => {
              capabilities: %i[audio_generation],
              modalities_input: %w[text],
              modalities_output: %w[audio]
            }
          }.freeze

          class << self
            attr_writer :registry_publisher

            def slug = 'openai'
            def configuration_requirements = %i[openai_api_key]

            def configuration_options
              %i[
                openai_api_key
                openai_api_base
                openai_organization_id
                openai_project_id
                openai_use_system_role
              ]
            end

            def capabilities = Capabilities

            def registry_publisher
              @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :openai)
            end
          end

          # Provider-level capability checks based on current OpenAI model families.
          module Capabilities
            module_function

            CAPABILITY_CHECKS = {
              'streaming' => :streaming?,
              'function_calling' => :functions?,
              'vision' => :vision?,
              'embeddings' => :embeddings?,
              'moderation' => :moderation?,
              'image' => :images?,
              'audio_transcription' => :audio_transcription?
            }.freeze

            def chat?(model) = !non_chat_model?(model_id(model))
            def streaming?(model) = chat?(model)
            def functions?(model) = model_id(model).match?(/^(gpt|o\d)/)
            def vision?(model) = model_id(model).match?(/^(gpt|o\d|omni-moderation)/)
            def embeddings?(model) = model_id(model).start_with?('text-embedding-')
            def moderation?(model) = model_id(model).include?('moderation')
            def images?(model) = model_id(model).match?(/^(gpt-image|dall-e)/)
            def audio_transcription?(model) = model_id(model).match?(/^(gpt-4o.*transcribe|whisper)/)

            def critical_capabilities_for(model)
              id = model_id(model)
              CAPABILITY_CHECKS.filter_map { |capability, predicate| capability if public_send(predicate, id) }
            end

            def model_id(model)
              return model.fetch('id', '') if model.is_a?(Hash)

              model.respond_to?(:id) ? model.id.to_s : model.to_s
            end

            def non_chat_model?(id)
              embeddings?(id) || moderation?(id) || images?(id) || audio_transcription?(id) ||
                id.match?(/^(tts|gpt-realtime|sora)/)
            end
          end

          def stream_usage_supported? = true

          def settings
            Openai.default_settings
          end

          def api_base
            config.openai_api_base || settings.dig(:instances, :default, :endpoint) || 'https://api.openai.com'
          end

          # Canonical translator instance - the provider boundary contract.
          # Created lazily; delegate translation to the Translator class.
          def translator
            @translator ||= Translator.new(api_base: api_base, headers: headers)
          end

          def headers
            identity_headers.merge({
              'Authorization' => "Bearer #{config.openai_api_key}",
              'OpenAI-Organization' => config.openai_organization_id,
              'OpenAI-Project' => config.openai_project_id
            }.compact)
          end

          def chat_url = completion_url
          def image_generation_url = '/v1/images/generations'
          def image_edit_url = '/v1/images/edits'
          def image_variation_url = '/v1/images/variations'
          def images_url(with: nil, mask: nil) = super

          def retrieve_model(model)
            log.debug { "Retrieving OpenAI model: #{model}" }
            connection.get("#{models_url}/#{model}").body
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true,
                                operation: 'retrieve_model')
            raise
          end

          def list_models(**)
            log.debug('Listing OpenAI models')
            raw = connection.get(models_url)
            models = build_model_infos(raw.body)
            log.debug { "Discovered #{models.size} OpenAI models; publishing registry availability" }
            self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            models
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true,
                                operation: 'list_models')
            raise
          end

          def discover_offerings(live: false, **)
            models = if live
                       @cached_models = list_models
                     else
                       Array(@cached_models)
                     end
            offerings = models.filter_map { |model_info| offering_from_model(model_info) }
            log.debug { "built #{offerings.size} OpenAI offering(s) live=#{live}" }
            offerings
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'openai.discover_offerings')
            []
          end

          # ── CapabilityPolicy integration ─────────────────────────────────
          # Maps raw CAPABILITY_MAP symbol arrays to the boolean hash format
          # that CapabilityPolicy.resolve expects as :provider_catalog.
          CATALOG_CAPABILITY_MAPPING = {
            streaming: :streaming,
            function_calling: :tools,
            tools: :tools,
            vision: :vision,
            structured_output: :structured_output,
            reasoning: :thinking,
            embedding: :embeddings,
            image_generation: :image,
            audio_transcription: :audio_transcription,
            audio_generation: :audio_speech
          }.freeze

          private

          def build_model_infos(body)
            body.fetch('data', []).map do |raw_model|
              id = raw_model.fetch('id')
              cap_entry = capability_entry_for(id)
              detail = model_detail(id)
              ctx = detail&.dig(:context_window) || cap_entry[:context_window]

              Legion::Extensions::Llm::Model::Info.new(
                id: id,
                name: id,
                provider: :openai,
                capabilities: cap_entry[:capabilities],
                context_length: ctx,
                modalities_input: cap_entry[:modalities_input],
                modalities_output: cap_entry[:modalities_output],
                metadata: {
                  created_at: model_created_at(raw_model['created']),
                  raw: raw_model
                }.compact
              )
            end
          end

          def capability_entry_for(model_id)
            CAPABILITY_MAP.each do |prefix, entry|
              return entry if model_id.start_with?(prefix)
            end

            {
              capabilities: %i[completion streaming],
              modalities_input: %w[text],
              modalities_output: %w[text]
            }
          end

          def offering_from_model(model_info)
            policy = resolve_model_policy(model_info)

            Legion::Extensions::Llm::Routing::ModelOffering.new(
              offering_attrs_for(model_info, policy)
            )
          end

          def resolve_model_policy(model_info)
            catalog = capabilities_to_boolean_hash(capability_entry_for(model_info.id)[:capabilities])

            Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: {},
              provider_catalog: catalog,
              probe: {},
              provider_envelope: {},
              provider_config: provider_capability_config,
              instance_config: instance_capability_config,
              model_config: model_capability_config(model_info.id)
            )
          end

          def offering_attrs_for(model_info, policy)
            {
              provider_family: :openai,
              instance_id: config.respond_to?(:instance_id) ? config.instance_id : :default,
              transport: :http,
              tier: :frontier,
              model: model_info.id,
              canonical_model_alias: model_info.respond_to?(:name) ? model_info.name : nil,
              model_family: infer_model_family(model_info.id),
              usage_type: infer_usage_type(model_info),
              capabilities: policy[:capabilities],
              capability_sources: policy[:sources],
              limits: { context_window: model_info.context_length }.compact,
              metadata: { capability_sources: policy[:sources] }
            }
          end

          def capabilities_to_boolean_hash(capability_symbols)
            return {} unless capability_symbols.is_a?(Array)

            result = {}
            capability_symbols.each do |sym|
              mapped = CATALOG_CAPABILITY_MAPPING[sym]
              result[mapped] = true if mapped
            end
            result
          end

          def provider_capability_config
            return {} unless defined?(Legion::Extensions::Llm::CredentialSources)

            conf = Legion::Extensions::Llm::CredentialSources.setting(:extensions, :llm, :openai)
            conf.is_a?(Hash) ? conf.to_h.except(:instances, 'instances') : {}
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'openai.provider_capability_config')
            {}
          end

          def instance_capability_config
            cfg = config
            result = {}
            %i[capabilities enable_thinking enable_tools enable_streaming enable_vision enable_embeddings
               thinking_flag tools_flag streaming_flag vision_flag embedding_flag embeddings_flag
               tool_flag images_flag image_flag].each do |key|
              next unless cfg.respond_to?(key)

              val = cfg.send(key)
              result[key] = val unless val.nil?
            rescue StandardError
              next
            end
            result
          end

          def model_capability_config(model_id)
            models_conf = fetch_models_config
            return {} unless models_conf.respond_to?(:to_h)

            models_conf.to_h[model_id.to_s] || models_conf.to_h[model_id.to_sym] || {}
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'openai.model_capability_config')
            {}
          end

          def fetch_models_config
            return config.models if config.respond_to?(:models)
            return config[:models] if config.respond_to?(:[])

            nil
          end

          def infer_model_family(model_id)
            CAPABILITY_MAP.each_key do |prefix|
              return prefix.tr('-', '_').to_sym if model_id.start_with?(prefix)
            end
            :unknown
          end

          def infer_usage_type(model_info)
            caps = model_info.respond_to?(:capabilities) ? Array(model_info.capabilities) : []
            return :embedding if caps.include?(:embedding)
            return :moderation if caps.include?(:moderation)
            return :image if caps.include?(:image_generation)

            :inference
          end

          def fetch_model_detail(model_name)
            entry = capability_entry_for(model_name)
            ctx = entry[:context_window]
            ctx ? { context_window: ctx } : nil
          end

          def model_created_at(value)
            value.is_a?(Numeric) ? Time.at(value).utc : value
          end

          def maybe_normalize_temperature(temperature, model)
            model_id = model.id.to_s
            return nil if model_id.include?('-search')
            return 1.0 if model_id.match?(/^(o\d|gpt-5)/) && !temperature.nil? && (temperature.to_f - 1.0).abs.positive?

            temperature
          end
        end
      end
    end
  end
end
