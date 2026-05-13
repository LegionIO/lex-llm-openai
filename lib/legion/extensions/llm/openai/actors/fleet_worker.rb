# frozen_string_literal: true

require 'legion/extensions/llm/openai'
require 'legion/extensions/llm/fleet/provider_responder'

unless defined?(Legion::Extensions::Actors::Subscription)
  begin
    require 'legion/extensions/actors/subscription'
  rescue LoadError => e
    Legion::Extensions::Llm::Openai.handle_exception(
      e,
      level: :warn,
      handled: true,
      operation: 'openai.fleet_worker.load_subscription'
    )
  end
end

unless defined?(Legion::Extensions::Actors::Subscription)
  raise LoadError, 'LegionIO actor runtime is required for OpenAI fleet worker'
end

module Legion
  module Extensions
    module Llm
      module Openai
        module Actor
          # Subscription actor for OpenAI fleet request consumption.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            include Legion::Logging::Helper

            def runner_class
              'Legion::Extensions::Llm::Openai::Runners::FleetWorker'
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              instances = Openai.discover_instances
              enabled = Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(instances)
              log.debug { "OpenAI fleet worker enablement: enabled=#{enabled}, instance_count=#{instances.size}" }
              enabled
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'openai.fleet_worker.enabled')
              false
            end
          end
        end
      end
    end
  end
end
