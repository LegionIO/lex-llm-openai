# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/openai/provider'

module Legion
  module Extensions
    module Llm
      module Openai
        module Runners
          # Runner entrypoint for OpenAI fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Openai::PROVIDER_FAMILY,
                provider_class: Openai::Provider,
                provider_instances: -> { Openai.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
