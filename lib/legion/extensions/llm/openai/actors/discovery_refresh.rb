# frozen_string_literal: true

require 'digest'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

begin
  require 'legion/extensions/llm/inventory/scoped_refresher'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

module Legion
  module Extensions
    module Llm
      module Openai
        module Actor
          # Periodically refreshes the OpenAI model discovery cache.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Logging::Helper

            if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              include Legion::Extensions::Llm::Inventory::ScopedRefresher
            end

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return self.class.every_seconds unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :openai, :discovery_interval) || self.class.every_seconds
            end

            def scope_key
              { provider: :openai }
            end

            def compute_lanes_for_scope
              return [] unless defined?(Legion::LLM::Call::Registry)

              instances = Legion::LLM::Call::Registry.all_instances.select do |e|
                (e[:provider] || '').to_sym == :openai
              end

              lanes = []
              instances.each { |entry| lanes.concat(lanes_for_instance(entry)) }
              lanes
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'openai.actor.discovery_refresh.compute_lanes')
              []
            end

            def credential_hash
              settings = Legion::Settings.dig(:extensions, :llm, :openai) || {}
              Digest::SHA256.hexdigest(settings[:api_key].to_s + settings[:instances].to_s)[0, 16]
            rescue StandardError
              'unknown'
            end

            def manual
              tick_if_scoped_refresher
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'openai.actor.discovery_refresh')
            end

            private

            def tick_if_scoped_refresher
              return unless defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              return unless self.class.ancestors.include?(Legion::Extensions::Llm::Inventory::ScopedRefresher)

              tick
            end

            def lanes_for_instance(instance_entry) # rubocop:disable Metrics/CyclomaticComplexity
              adapter = instance_entry[:adapter]
              return [] unless adapter.respond_to?(:discover_offerings)

              instance_id = instance_entry[:instance] || instance_entry[:instance_id] ||
                            instance_entry[:id] || :default
              lanes = []

              Array(adapter.discover_offerings(live: true)).each do |raw_offering|
                offering = offering_to_hash(raw_offering)
                next unless offering

                lane = build_lane(offering, instance_id)
                lanes << lane
                fleet_lane = maybe_fleet_lane(offering, lane)
                lanes << fleet_lane if fleet_lane
              end

              lanes
            end

            def offering_to_hash(offering)
              return nil if offering.nil?
              return offering if offering.is_a?(Hash)

              hash = offering.to_h
              hash[:type] ||= hash[:usage_type]
              hash[:enabled] = offering.respond_to?(:enabled?) ? offering.enabled? : true
              hash
            end

            def build_lane(offering, instance_id)
              tier = offering[:tier] || :frontier
              type = offering_type(offering)
              lane_fields = { tier: tier, provider_family: :openai, instance_id: instance_id,
                              type: type, model: offering[:model] }
              {
                id: Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(lane_fields),
                tier: tier,
                provider_family: :openai,
                instance_id: instance_id,
                model: offering[:model],
                canonical_model_alias: offering[:canonical_model_alias],
                type: type,
                capabilities: normalize_capabilities(offering[:capabilities]),
                limits: offering[:limits] || {},
                enabled: offering.fetch(:enabled, true),
                cost: offering[:cost]
              }
            end

            def maybe_fleet_lane(offering, lane)
              return nil unless offering_type(offering) == :inference

              settings = Legion::Settings.dig(:extensions, :llm, :openai) || {}
              return nil unless settings[:fleet]&.dig(:dispatch, :enabled)

              fleet_fields = {
                tier: :fleet,
                provider_family: lane[:provider_family],
                instance_id: lane[:instance_id],
                type: lane[:type],
                model: lane[:model]
              }
              lane.merge(
                id: Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(fleet_fields),
                tier: :fleet
              )
            end

            def offering_type(offering)
              %i[embed embedding].include?(offering[:type]) ? :embedding : :inference
            end

            def normalize_capabilities(caps)
              if defined?(Legion::Extensions::Llm::Inventory::Capabilities) &&
                 Legion::Extensions::Llm::Inventory::Capabilities.respond_to?(:normalize)
                Legion::Extensions::Llm::Inventory::Capabilities.normalize(caps)
              else
                Array(caps)
              end
            end
          end
        end
      end
    end
  end
end
