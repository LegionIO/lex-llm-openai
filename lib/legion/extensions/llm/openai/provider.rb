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
              capabilities: %i[completion streaming function_calling vision structured_output],
              modalities_input: %w[text image audio],
              modalities_output: %w[text]
            },
            'gpt-4.1' => {
              capabilities: %i[completion streaming function_calling vision structured_output],
              modalities_input: %w[text image],
              modalities_output: %w[text]
            },
            'gpt-4' => {
              capabilities: %i[completion streaming function_calling vision],
              modalities_input: %w[text image],
              modalities_output: %w[text]
            },
            'gpt-5' => {
              capabilities: %i[completion streaming function_calling vision structured_output reasoning],
              modalities_input: %w[text image],
              modalities_output: %w[text]
            },
            'o4' => {
              capabilities: %i[completion streaming function_calling vision reasoning],
              modalities_input: %w[text image],
              modalities_output: %w[text]
            },
            'o3' => {
              capabilities: %i[completion streaming function_calling vision reasoning],
              modalities_input: %w[text image],
              modalities_output: %w[text]
            },
            'o1' => {
              capabilities: %i[completion streaming function_calling vision reasoning],
              modalities_input: %w[text image],
              modalities_output: %w[text]
            },
            'text-embedding-' => {
              capabilities: %i[embedding],
              modalities_input: %w[text],
              modalities_output: %w[embeddings]
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

          def api_base
            config.openai_api_base || 'https://api.openai.com'
          end

          def headers
            {
              'Authorization' => "Bearer #{config.openai_api_key}",
              'OpenAI-Organization' => config.openai_organization_id,
              'OpenAI-Project' => config.openai_project_id
            }.compact
          end

          def chat_url = completion_url
          def image_generation_url = '/v1/images/generations'
          def image_edit_url = '/v1/images/edits'
          def image_variation_url = '/v1/images/variations'
          def images_url(with: nil, mask: nil) = super

          def retrieve_model(model)
            log.info("Retrieving model: #{model}")
            connection.get("#{models_url}/#{model}").body
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true,
                                operation: 'retrieve_model')
            raise
          end

          def list_models
            log.info('Listing OpenAI models')
            raw = connection.get(models_url)
            models = build_model_infos(raw.body)
            log.info("Discovered #{models.size} OpenAI models")
            self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            models
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true,
                                operation: 'list_models')
            raise
          end

          private

          def build_model_infos(body)
            body.fetch('data', []).map do |raw_model|
              id = raw_model.fetch('id')
              cap_entry = capability_entry_for(id)

              Legion::Extensions::Llm::Model::Info.new(
                id: id,
                name: id,
                provider: :openai,
                capabilities: cap_entry[:capabilities],
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

            # Fallback for unknown models: assume chat-capable
            {
              capabilities: %i[completion streaming],
              modalities_input: %w[text],
              modalities_output: %w[text]
            }
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

# Register configuration options so Legion::Extensions::Llm::Configuration knows about them.
if Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
  Legion::Extensions::Llm::Configuration.register_provider_options(
    Legion::Extensions::Llm::Openai::Provider.configuration_options
  )
end
