# frozen_string_literal: true

require 'time'

module Legion
  module Extensions
    module Llm
      module Openai
        # Display-only health + capabilities projection into
        # settings[:instances][<config_name>] after each registry commit.
        # The in-memory AvailabilityFact remains the routing authority; the
        # settings writes are plain serializable data read by the legion-llm
        # status API (D14). <config_name> is the settings key the instance was
        # discovered under — never the derived host:port id.
        module DiscoveryHealthDisplay
          # Fleet operation → display capability name for the settings
          # projection read by the status API.
          LEGACY_CAPABILITY_NAMES = {
            chat: :completion,
            stream_chat: :streaming,
            embed: :embedding,
            image: :image,
            transcribe: :audio_transcription,
            translate: :audio_transcription,
            speak: :audio_speech,
            moderate: :moderation
          }.freeze

          private

          # rubocop:disable Metrics/ParameterLists
          def write_instance_health(config_name:, available:, reason:, probe_outcome:, source:, capabilities: nil)
            instance_settings = ensure_instance_settings(config_name)
            instance_settings[:health] = build_health_display(
              available: available, reason: reason, probe_outcome: probe_outcome, source: source
            )
            instance_settings[:capabilities] = capabilities unless capabilities.nil?
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'openai.actor.write_instance_health',
                                instance_name: config_name.to_s)
          end
          # rubocop:enable Metrics/ParameterLists

          def ensure_instance_settings(config_name)
            instances = settings[:instances]
            instances = settings[:instances] = {} unless instances.is_a?(Hash)
            instance_settings = instances[config_name]
            instance_settings = instances[config_name] = {} unless instance_settings.is_a?(Hash)
            instance_settings
          end

          def build_health_display(available:, reason:, probe_outcome:, source:)
            {
              circuit_state: available ? :closed : :open,
              denied: false,
              available: available,
              adjustment: available ? 0 : -50,
              reason: reason,
              observed_at: Time.now.utc.iso8601,
              last_probe_outcome: probe_outcome,
              source: source
            }
          end

          def clear_instance_health(config_name:)
            instances = settings[:instances]
            return unless instances.is_a?(Hash)

            instance_settings = instances[config_name]
            return unless instance_settings.is_a?(Hash)

            instance_settings.delete(:health)
            instance_settings.delete(:capabilities)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'openai.actor.clear_instance_health',
                                instance_name: config_name.to_s)
          end

          def instance_capabilities(offerings)
            operations = Set.new
            offerings.each do |draft|
              draft.operation_evidence.each_value do |evidence|
                operations << evidence.operation if evidence.supported?
              end
            end
            operations.filter_map { |op| LEGACY_CAPABILITY_NAMES[op] }.uniq.sort
          end
        end
      end
    end
  end
end
