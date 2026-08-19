# frozen_string_literal: true

require 'legion/extensions/llm/inventory/weight_reconciler'

module Legion
  module Extensions
    module Llm
      module Openai
        # Binds the shared write-time weight reconciler to OpenAI's existing
        # periodic discovery actor. Settings are read only during ordinary
        # actor passes; this module never registers reload/reset callbacks.
        module DiscoveryWeightPublication
          private

          def initialize_weight_publication
            @instance_states ||= {}
            @instance_state_mutex ||= Mutex.new
            dormant_weight_tracker
          end

          def dormant_weight_tracker
            @dormant_weight_tracker ||= Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
          end

          def commit_discovered_offerings(instance_id:, state:, offerings:)
            Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
              settings: Legion::Settings,
              instance_id: instance_id,
              state: state,
              discovered_offerings: offerings,
              mutex: @instance_state_mutex,
              equivalent: lambda do |previous, current|
                !offerings_changed?(previous: previous, current: current)
              end,
              replace: method(:replace_weight_snapshot)
            )
          end

          def replace_weight_snapshot(instance_id:, state:, offerings:, sequence:)
            publisher.replace_instance_snapshot(
              instance_id: instance_id,
              physical_id: state.fetch(:physical_id),
              publisher_token: state.fetch(:publisher_token),
              offerings: offerings,
              sequence: sequence
            )
          end

          def activate_weight_snapshot(instance_id:, state:, offerings:, sequence:, probe_token:)
            publisher.activate_instance_snapshot(
              instance_id: instance_id,
              physical_id: state.fetch(:physical_id),
              publisher_token: state.fetch(:publisher_token),
              offerings: offerings,
              sequence: sequence,
              probe_token: probe_token
            )
          end

          def tracked_instance_state(instance_id)
            return unless @instance_states && @instance_state_mutex

            @instance_state_mutex.synchronize { @instance_states[instance_id] }
          end

          def instance_states_snapshot
            @instance_state_mutex.synchronize { @instance_states.each_pair.to_h }
          end

          def update_tracked_instance(instance_id, state)
            @instance_state_mutex.synchronize do
              return false unless @instance_states[instance_id].equal?(state)

              yield
              true
            end
          end

          def tracked_instance?(instance_id, state)
            tracked_instance_state(instance_id).equal?(state)
          end

          def observe_dormant_weights
            Legion::Extensions::Llm::Inventory::WeightReconciler.observe_dormant!(
              settings: Legion::Settings,
              provider_family: :openai,
              states: @instance_states,
              mutex: @instance_state_mutex,
              tracker: dormant_weight_tracker,
              dormant_logger: lambda do |key|
                log.info do
                  "[llm][openai] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true"
                end
              end
            )
          end
        end
      end
    end
  end
end
