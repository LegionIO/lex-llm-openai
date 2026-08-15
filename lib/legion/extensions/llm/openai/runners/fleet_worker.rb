# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/openai'

module Legion
  module Extensions
    module Llm
      module Openai
        module Runners
          # Runner entrypoint for OpenAI fleet request execution.
          # Subscription dispatch invokes this via Legion::Runner.run as
          # `runner_class.send('handle_fleet_request', **envelope)` — the fleet
          # envelope arrives as kwargs (symbol keys), never as a positional
          # payload.
          module FleetWorker
            extend Legion::Logging::Helper

            module_function

            def handle_fleet_request(**envelope)
              log.debug do
                "Handling OpenAI fleet request: request_id=#{envelope[:request_id] || 'unknown'}, " \
                  "provider_instance=#{envelope[:provider_instance] || 'unknown'}"
              end

              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: envelope,
                provider_family: Openai::PROVIDER_FAMILY,
                provider_class: Openai::Provider,
                provider_instances: -> { Openai.discover_instances }
              )
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'openai.fleet_worker.handle_request')
              raise
            end
          end
        end
      end
    end
  end
end
