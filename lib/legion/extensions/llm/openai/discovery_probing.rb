# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Openai
        # Readiness probing, cadence/reactive probe reporting, and HTTP
        # connection building for DiscoveryRefresh. Readiness is a non-
        # inference, non-billable /v1/models GET.
        module DiscoveryProbing
          private

          # -- Readiness check (non-inference: /v1/models) -----------------------

          def check_readiness(instance_cfg:)
            conn = build_api_connection(instance_cfg: instance_cfg)
            response = conn.get('/v1/models')
            build_readiness_from_response(response: response, instance_cfg: instance_cfg)
          rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
            handle_exception(e, level: :warn, handled: true, operation: 'openai.actor.check_readiness')
            readiness_failure(reason: "OpenAI /v1/models network error: #{e.message}", error: e)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'openai.actor.check_readiness')
            readiness_failure(reason: "OpenAI /v1/models error: #{e.message}", error: e)
          end

          def build_readiness_from_response(response:, instance_cfg:)
            Legion::Extensions::Llm::Inventory::ReadinessResult.new(
              ready: response.status == 200,
              reason: "OpenAI /v1/models returned #{response.status}",
              metadata: { status: response.status, api_base: api_base_for(instance_cfg) }
            )
          end

          def readiness_failure(reason:, error:)
            Legion::Extensions::Llm::Inventory::ReadinessResult.new(
              ready: false,
              reason: reason,
              metadata: { error_class: error.class.name }
            )
          end

          # -- Cadence / reactive probes -----------------------------------------

          def run_cadence_probe(instance_id:, state:)
            coordinator = state[:probe_coordinator]
            return unless coordinator.begin_probe

            probe_token = publisher.readiness_probe_started(
              instance_id: instance_id,
              physical_id: state[:physical_id],
              publisher_token: state[:publisher_token]
            )

            readiness = check_readiness(instance_cfg: state[:instance_cfg])
            coordinator.finish_probe

            report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness, state: state)
          rescue StandardError => e
            begin
              coordinator&.finish_probe
            rescue StandardError => finish_err
              handle_exception(finish_err, level: :warn, operation: 'openai.actor.cadence_probe.finish_probe',
                                           instance_id: instance_id)
            end
            handle_exception(e, level: :warn, operation: 'openai.actor.cadence_probe',
                                instance_id: instance_id)
          end

          def handle_reactive_probe(instance_id:, request:)
            state = tracked_instance_state(instance_id)
            return unless state

            coordinator = state[:probe_coordinator]
            return unless coordinator.begin_probe(request: request)

            probe_token = publisher.readiness_probe_started(
              instance_id: instance_id,
              physical_id: state[:physical_id],
              publisher_token: state[:publisher_token]
            )

            readiness = check_readiness(instance_cfg: state[:instance_cfg])
            coordinator.finish_probe(request: request)

            report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness, state: state)
          rescue StandardError => e
            begin
              coordinator&.finish_probe(request: request)
            rescue StandardError => finish_err
              handle_exception(finish_err, level: :warn, operation: 'openai.actor.reactive_probe.finish_probe',
                                           instance_id: instance_id)
            end
            handle_exception(e, level: :warn, operation: 'openai.actor.reactive_probe',
                                instance_id: instance_id)
          end

          def build_probe_enqueue(instance_id:)
            proc do |request:|
              handle_reactive_probe(instance_id: instance_id, request: request)
              true
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'openai.actor.probe_enqueue',
                                  instance_id: instance_id)
              false
            end
          end
        end
      end
    end
  end
end
