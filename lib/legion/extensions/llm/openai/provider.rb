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
          # Maps model-id prefixes to a set of capabilities, modality
          # vectors, and the family context window. Feeds the discovery
          # runner's capability_entry_for (evidence publication) and the
          # provider's fetch_model_detail (cached model context).
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

          # Canonical OpenAI API base URL. Used as fallback when no custom
          # openai_api_base is configured on the provider instance.
          DEFAULT_ENDPOINT = 'https://api.openai.com'

          class << self
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
            config.openai_api_base || DEFAULT_ENDPOINT
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

          # The read path is the base discover_offerings (07 C5): activated
          # inventory offerings for this instance from the Registry snapshot.
          # Publication is the discovery runner's sole path.

          private

          # OpenAI wire dialect (08 R4): o-series and gpt-5 reject temperature
          # values other than 1.0, and search models take no temperature at
          # all. The base funnel enforces canonical input before any rendering
          # (08 F2); this render-path hook is the home of the per-model
          # normalization.
          def render_payload(messages, tools:, model:, stream:, schema:, thinking:, params:, tool_prefs:) # rubocop:disable Metrics/ParameterLists
            payload = super
            temperature = params&.temperature
            return payload if temperature.nil?

            normalized = normalize_openai_temperature(temperature, model)
            if normalized.nil?
              payload.delete(:temperature)
            else
              payload[:temperature] = normalized
            end
            payload
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

          def fetch_model_detail(model_name)
            entry = capability_entry_for(model_name)
            ctx = entry[:context_window]
            ctx ? { context_window: ctx } : nil
          end

          # Per-model temperature normalization (the OpenAI wire dialect):
          # search models take no temperature; o-series and gpt-5 only accept
          # 1.0. Called from the render path with the canonical params value.
          def normalize_openai_temperature(temperature, model)
            model_id = model.to_s
            return nil if model_id.include?('-search')
            return 1.0 if model_id.match?(/^(o\d|gpt-5)/) && !temperature.nil? && (temperature.to_f - 1.0).abs.positive?

            temperature
          end
        end
      end
    end
  end
end
