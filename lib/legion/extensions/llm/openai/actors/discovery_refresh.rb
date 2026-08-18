# frozen_string_literal: true

require 'faraday'
require 'uri'

require 'legion/extensions/llm/openai/openai_callable'
require 'legion/extensions/llm/openai/instance_discovery'
require 'legion/extensions/llm/openai/discovery_evidence_builders'
require 'legion/extensions/llm/openai/discovery_drafts'
require 'legion/extensions/llm/openai/discovery_identity'
require 'legion/extensions/llm/openai/discovery_probing'
require 'legion/extensions/llm/openai/discovery_transport'
require 'legion/extensions/llm/openai/discovery_health_display'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/scoped_refresher'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  Legion::Logging.warn("[openai] LegionIO actor runtime unavailable: #{e.message}")
end

unless defined?(Legion::Extensions::Actors::Every)
  raise LoadError, 'LegionIO actor runtime is required for the OpenAI discovery actor'
end

module Legion
  module Extensions
    module Llm
      module Openai
        module Actor
          # SSOT v3 periodic discovery actor for OpenAI provider instances.
          # Claims configured instances, discovers models via /v1/models,
          # probes readiness via /v1/models, and publishes complete
          # OfferingDraft snapshots through the Inventory::Publisher.
          #
          # Instance identity is the operator's CONFIG NAME
          # (InstanceKey.instance_id) — the key the router uses for
          # instances.<name> settings lookups and per-instance tuning. The
          # derived host:port/credential-fingerprint is the secondary
          # physical_id (dedup/diagnostics only); two config names at the
          # same endpoint stay distinct instances.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper
            include Legion::Extensions::Llm::Openai::DiscoveryEvidenceBuilders
            include Legion::Extensions::Llm::Openai::DiscoveryDrafts
            include Legion::Extensions::Llm::Openai::DiscoveryIdentity
            include Legion::Extensions::Llm::Openai::DiscoveryProbing
            include Legion::Extensions::Llm::Openai::DiscoveryTransport
            include Legion::Extensions::Llm::Openai::DiscoveryHealthDisplay

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              discovery_interval_seconds
            end

            def manual
              @instance_states ||= {}
              tick_refresh
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'openai.actor.discovery_refresh')
            end

            def shutdown
              return unless @instance_states

              @instance_states.each_key { |instance_id| remove_instance_state(instance_id) }
            end

            private

            # -- Publisher ----------------------------------------------------------

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(
                provider_family: :openai,
                compatibility_adapter: Legion::Extensions::Llm::Inventory::ScopedRefresher::LegacyCoordinatorAdapter.new(
                  provider_family: :openai
                )
              )
            end

            # -- Cadence interval (D9) ----------------------------------------------

            def discovery_interval_seconds
              interval = settings[:discovery].is_a?(Hash) ? settings[:discovery][:interval_seconds] : nil
              interval.is_a?(Integer) && interval.positive? ? interval : registered_discovery_interval_seconds
            end

            def registered_discovery_interval_seconds
              Legion::Extensions::Llm::Openai.default_settings[:discovery][:interval_seconds]
            end

            # -- Tick refresh ------------------------------------------------------

            def tick_refresh
              reconcile_configured_instances
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'openai.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            # Re-scans configured instances every tick so instances configured
            # after boot appear without a restart, and removed instances are
            # released from the registry. Credential-less candidates (e.g. the
            # synthetic instances.default placeholder) are skipped, not claimed.
            def reconcile_configured_instances
              discovered = Legion::Extensions::Llm::Openai.discover_instances
              claim_new_instances(discovered)
              release_removed_instances(discovered)
            end

            def claim_new_instances(discovered)
              discovered.each do |name, instance_cfg|
                next if @instance_states.key?(name.to_s)
                next unless claimable_instance?(name: name, instance_cfg: instance_cfg)

                @instance_states[name.to_s] = build_instance_context(
                  name: name, instance_cfg: instance_cfg
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'openai.actor.claim_instance',
                                    instance_name: name.to_s)
              end
            end

            def release_removed_instances(discovered)
              discovered_names = discovered.keys.map(&:to_s)
              (@instance_states.keys - discovered_names).each { |instance_id| remove_instance_state(instance_id) }
            end

            def claimable_instance?(name:, instance_cfg:)
              return true if instance_credential?(instance_cfg)

              warn_unclaimable_instance(name: name)
              false
            end

            def instance_credential?(instance_cfg)
              valid_string?(instance_cfg[:openai_api_key] || instance_cfg[:api_key])
            end

            # Warns once per actor lifetime (per instance name) so the skip
            # is loud without spamming every tick: skipped instances (the
            # synthetic instances.default placeholder is the normal case)
            # never enter @instance_states, so an unthrottled warn re-fired
            # on every discovery tick.
            def warn_unclaimable_instance(name:)
              skip_warned = (@skip_warned ||= {})
              return if skip_warned[name.to_s]

              skip_warned[name.to_s] = true
              log.warn("[openai] skipping instance #{name}: no API credential configured")
            end

            def build_instance_context(name:, instance_cfg:)
              physical_id = derive_physical_id(instance_cfg: instance_cfg)
              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :openai, instance_id: name.to_s, physical_id: physical_id
              )
              callable = Legion::Extensions::Llm::Openai::OpenaiCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id: name.to_s)
              )
              publisher_token = publisher.claim_instance(
                instance_id: name.to_s,
                physical_id: physical_id,
                callable: callable,
                probe_request_handle: probe_coordinator
              )
              {
                name: name, instance_key: instance_key, physical_id: physical_id,
                instance_cfg: instance_cfg,
                callable: callable, probe_coordinator: probe_coordinator,
                publisher_token: publisher_token, sequence: 0, last_probe_outcome: nil,
                offerings: discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              }
            end

            def refresh_instance(instance_id:, state:)
              status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
              return log.debug { "[openai] no publication status for #{instance_id}; skipping refresh" } if status.nil?

              if status.state == :initializing
                run_initialization_probe(instance_id: instance_id, state: state)
              else
                refresh_activated_instance(instance_id: instance_id, state: state)
              end
            end

            # D4: an instance whose initial readiness failed stays :initializing.
            # activate_instance_snapshot is the only transition legal from
            # :initializing, so a later passing probe re-activates the claim
            # (fresh probe token, current offerings, next sequence) instead of
            # calling replace/readiness_succeeded, which would raise
            # InvalidTransitionError.
            def run_initialization_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                physical_id: state[:physical_id],
                publisher_token: state[:publisher_token]
              )
              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe

              apply_initial_readiness(
                instance_id: instance_id, state: state, probe_token: probe_token, readiness: readiness
              )
            rescue StandardError => e
              begin
                coordinator&.finish_probe
              rescue StandardError => finish_err
                handle_exception(finish_err, level: :warn,
                                             operation: 'openai.actor.initialization_probe.finish_probe',
                                             instance_id: instance_id)
              end
              handle_exception(e, level: :warn, operation: 'openai.actor.initialization_probe',
                                  instance_id: instance_id)
            end

            def apply_initial_readiness(instance_id:, state:, probe_token:, readiness:)
              if readiness.ready?
                activate_after_readiness(instance_id: instance_id, state: state, probe_token: probe_token)
              else
                report_initial_failure(
                  instance_id: instance_id, state: state, probe_token: probe_token, reason: readiness.reason
                )
              end
            end

            def activate_after_readiness(instance_id:, state:, probe_token:)
              state[:sequence] += 1
              state[:last_probe_outcome] = :success
              publisher.activate_instance_snapshot(
                instance_id: instance_id,
                physical_id: state[:physical_id],
                publisher_token: state[:publisher_token],
                offerings: state[:offerings],
                sequence: state[:sequence],
                probe_token: probe_token
              )
              write_instance_health(
                config_name: state[:name], available: true, reason: 'startup readiness succeeded',
                probe_outcome: :success, source: :startup_readiness,
                capabilities: instance_capabilities(state[:offerings])
              )
            end

            def report_initial_failure(instance_id:, state:, probe_token:, reason:)
              state[:last_probe_outcome] = :failure
              publisher.readiness_failed(
                instance_id: instance_id, physical_id: state[:physical_id],
                probe_token: probe_token, reason: reason
              )
              write_instance_health(
                config_name: state[:name], available: false, reason: reason,
                probe_outcome: :failure, source: :startup_readiness
              )
            end

            def refresh_activated_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key]
              )

              if offerings_changed?(previous: state[:offerings], current: new_offerings)
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id,
                  physical_id: state[:physical_id],
                  publisher_token: state[:publisher_token],
                  offerings: new_offerings,
                  sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
                write_instance_health(
                  config_name: state[:name], available: true, reason: 'offerings refreshed',
                  probe_outcome: state[:last_probe_outcome], source: :discovery
                )
              end

              run_cadence_probe(instance_id: instance_id, state: state)
            end

            # -- Removal -----------------------------------------------------------

            def remove_instance_state(instance_id)
              state = @instance_states.delete(instance_id)
              return unless state

              publisher.remove_instance(
                instance_id: instance_id,
                physical_id: state[:physical_id],
                publisher_token: state[:publisher_token]
              )
              clear_instance_health(config_name: state[:name])
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'openai.actor.remove_instance',
                                  instance_id: instance_id)
            end

            # -- Model discovery ---------------------------------------------------

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              models = fetch_models(instance_cfg: instance_cfg)

              models.filter_map do |model_data|
                model_id = model_data[:id].to_s
                next if model_id.empty?

                build_offering_draft(
                  model_id: model_id,
                  model_data: model_data,
                  instance_cfg: instance_cfg,
                  instance_key: instance_key
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'openai.actor.discover_offerings')
              []
            end

            def fetch_models(instance_cfg:)
              conn = build_api_connection(instance_cfg: instance_cfg)
              response = conn.get('/v1/models')
              Legion::JSON.load(response.body).fetch(:data, [])
            end

            def build_offering_draft(model_id:, model_data:, instance_cfg:, instance_key:)
              tier = instance_cfg[:tier] || :frontier
              operations = infer_operations(model_id: model_id)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(operations: operations),
                capability_evidence: build_capability_evidence(model_id: model_id),
                context_evidence: build_context_evidence(model_id: model_id, model_data: model_data),
                max_output_evidence: build_max_output_evidence(model_data: model_data),
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(
                  model_id: model_id, model_data: model_data
                ),
                model_revision_evidence: build_model_revision_evidence(model_data: model_data),
                tokenizer_evidence: absent_value_evidence,
                quota_domains: build_quota_domains(instance_cfg: instance_cfg, operations: operations),
                metadata: build_offering_metadata(model_id: model_id, instance_key: instance_key).freeze,
                publication_source: :provider_catalog
              )
            end
          end
        end
      end
    end
  end
end
