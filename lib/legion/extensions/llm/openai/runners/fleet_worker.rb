# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/openai'

module Legion
  module Extensions
    module Llm
      module Openai
        module Runners
          # Runner entrypoint for OpenAI fleet request execution.
          module FleetWorker
            extend Legion::Logging::Helper

            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              log.debug do
                "Handling OpenAI fleet request: request_id=#{payload_value(payload, :request_id) || 'unknown'}, " \
                  "provider_instance=#{payload_value(payload, :provider_instance) || 'default'}"
              end

              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Openai::PROVIDER_FAMILY,
                provider_class: Openai::Provider,
                provider_instances: -> { Openai.discover_instances },
                delivery: delivery,
                properties: properties
              )
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'openai.fleet_worker.handle_request')
              raise
            end

            def payload_value(payload, key)
              return unless payload.respond_to?(:[])

              payload[key] || payload[key.to_s]
            end
          end
        end
      end
    end
  end
end
