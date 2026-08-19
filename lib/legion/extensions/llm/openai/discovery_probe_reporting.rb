# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Openai
        # Applies cadence/reactive readiness results after provider I/O.
        module DiscoveryProbeReporting
          private

          def report_probe_result(instance_id:, probe_token:, readiness:, state:)
            if readiness.ready?
              report_probe_success(instance_id: instance_id, probe_token: probe_token, state: state)
            else
              report_probe_failure(
                instance_id: instance_id, probe_token: probe_token, readiness: readiness, state: state
              )
            end
          end

          def report_probe_success(instance_id:, probe_token:, state:)
            publisher.readiness_succeeded(
              instance_id: instance_id, physical_id: state[:physical_id], probe_token: probe_token
            )
            updated = update_tracked_instance(instance_id, state) do
              state[:last_probe_outcome] = :success
            end
            return unless updated

            write_instance_health(
              config_name: state[:name], available: true, reason: 'readiness probe succeeded',
              probe_outcome: :success, source: :readiness_probe
            )
          end

          def report_probe_failure(instance_id:, probe_token:, readiness:, state:)
            publisher.readiness_failed(
              instance_id: instance_id, physical_id: state[:physical_id],
              probe_token: probe_token, reason: readiness.reason
            )
            updated = update_tracked_instance(instance_id, state) do
              state[:last_probe_outcome] = :failure
            end
            return unless updated

            write_instance_health(
              config_name: state[:name], available: false, reason: readiness.reason,
              probe_outcome: :failure, source: :readiness_probe
            )
          end
        end
      end
    end
  end
end
