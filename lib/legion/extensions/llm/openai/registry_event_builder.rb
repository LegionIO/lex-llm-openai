# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Openai
        # Builds sanitized lex-llm registry envelopes for OpenAI provider state.
        class RegistryEventBuilder
          def model_available(model, readiness:)
            registry_event_class.available(
              model_offering(model),
              runtime: runtime_metadata,
              health: model_health(readiness),
              metadata: model_metadata(model)
            )
          end

          private

          def model_offering(model)
            {
              provider_family: :openai,
              provider_instance: provider_instance,
              transport: :http,
              model: model.id,
              usage_type: usage_type_for(model),
              capabilities: Array(model.capabilities).map(&:to_sym),
              limits: model_limits(model),
              metadata: { lex: :llm_openai, model_name: model.name }.compact
            }
          end

          def model_health(readiness)
            ready = readiness.fetch(:ready, true) == true
            { ready:, status: ready ? :available : :degraded }
          end

          def model_metadata(model)
            { extension: :lex_llm_openai, provider: :openai, model_type: model.type }
          end

          def runtime_metadata
            { node: provider_instance }
          end

          def model_limits(model)
            {
              context_window: model.context_window,
              max_output_tokens: model.max_output_tokens
            }.compact
          end

          def usage_type_for(model)
            model.type == 'embedding' ? :embedding : :inference
          end

          def provider_instance
            configured_node = (::Legion::Settings.dig(:node, :canonical_name) if defined?(::Legion::Settings))
            value = configured_node.to_s.strip
            value.empty? ? :openai : value.to_sym
          rescue StandardError
            :openai
          end

          def registry_event_class
            ::Legion::Extensions::Llm::Routing::RegistryEvent
          end
        end
      end
    end
  end
end
