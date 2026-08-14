# frozen_string_literal: true

require 'digest'
require 'uri'
require_relative 'openai_callable'
require_relative 'discovery_evidence_builders'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Openai
        module Actor
          # SSOT v3 periodic discovery actor for OpenAI provider instances.
          # Claims instances, discovers models via /v1/models, probes readiness
          # via /v1/models, and publishes complete OfferingDraft snapshots through
          # the Inventory::Publisher.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper
            include DiscoveryEvidenceBuilders

            # Standard capability symbols mapped to their evidence key.
            # Reasoning maps to the :thinking evidence capability key.
            STANDARD_CAPABILITY_CHECKS = {
              completion: :completion,
              streaming: :streaming,
              vision: :vision,
              reasoning: :thinking,
              embedding: :embedding,
              structured_output: :structured_output
            }.freeze

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              self.class.every_seconds
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'openai.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'openai.actor.discovery_refresh.shutdown')
            end

            private

            # -- Publisher ----------------------------------------------------------

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :openai)
            end

            # -- Initial discovery -------------------------------------------------

            def initial_discovery
              @instance_states = {}
              discovered = Legion::Extensions::Llm::Openai.discover_instances
              discovered.each do |name, instance_cfg|
                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'openai.actor.claim_instance', instance_name: name.to_s)
              end
            end

            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = derive_instance_id(instance_cfg: instance_cfg)
              context = build_instance_context(name: name, instance_id: instance_id, instance_cfg: instance_cfg)
              run_initial_readiness(context: context)
              @instance_states[instance_id] = context
            end

            def build_instance_context(name:, instance_id:, instance_cfg:)
              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :openai, instance_id: instance_id
              )
              callable = OpenaiCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id: instance_id)
              )
              publisher_token = publisher.claim_instance(
                instance_id: instance_id,
                callable: callable,
                probe_request_handle: probe_coordinator
              )
              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              {
                name: name, instance_key: instance_key, instance_cfg: instance_cfg,
                callable: callable, probe_coordinator: probe_coordinator,
                publisher_token: publisher_token, sequence: 0, offerings: offerings
              }
            end

            def run_initial_readiness(context:)
              instance_id = context[:instance_key].instance_id
              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: context[:publisher_token]
              )
              readiness = check_readiness(instance_cfg: context[:instance_cfg])
              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: context[:publisher_token],
                  offerings: context[:offerings],
                  sequence: 0,
                  probe_token: probe_token
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end
            end

            # -- Tick refresh ------------------------------------------------------

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'openai.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key]
              )

              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token],
                  offerings: new_offerings,
                  sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
              end

              run_cadence_probe(instance_id: instance_id, state: state)
            end

            # -- Readiness probing -------------------------------------------------

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe

              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
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
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_readiness(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)

              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
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

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end
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

            # -- Operation inference -----------------------------------------------

            def infer_operations(model_id:)
              id = model_id.to_s.downcase
              return { embed: true } if id.start_with?('text-embedding-')
              return { moderate: true } if id.include?('moderation')
              return { image: true } if id.match?(/^(gpt-image|dall-e)/)
              return { transcribe: true } if id.match?(/^(whisper)/)
              return { speak: true } if id.match?(/^tts/)

              # Chat models support chat and stream_chat
              { chat: true, stream_chat: true }
            end

            # -- Quota domain ------------------------------------------------------

            def build_quota_domains(instance_cfg:, operations:)
              org = instance_cfg[:openai_organization_id]
              project = instance_cfg[:openai_project_id]

              return {} unless valid_string?(org)

              domain_id = build_domain_id(org: org, project: project)
              operations.each_key.to_h { |op| [op, domain_id] }
            end

            def build_domain_id(org:, project:)
              return "org:#{org.strip}/proj:#{project.strip}" if valid_string?(project)

              "org:#{org.strip}"
            end

            # -- Offering metadata -------------------------------------------------

            def build_offering_metadata(model_id:, instance_key:)
              {
                raw_model: model_id,
                instance_id: instance_key.instance_id
              }
            end

            # -- Instance ID derivation --------------------------------------------

            def derive_instance_id(instance_cfg:)
              base_url = api_base_for(instance_cfg)
              host_port = extract_host_port(url: base_url)
              parts = [host_port]
              parts.concat(identity_parts_for(instance_cfg))
              parts.join('/')
            end

            def identity_parts_for(instance_cfg)
              parts = []
              api_key = instance_cfg[:openai_api_key] || instance_cfg[:api_key]
              parts << api_key_fingerprint(api_key) if valid_string?(api_key)
              org_id = instance_cfg[:openai_organization_id]
              parts << "org:#{org_id.strip}" if valid_string?(org_id)
              project_id = instance_cfg[:openai_project_id]
              parts << "proj:#{project_id.strip}" if valid_string?(project_id)
              parts
            end

            def api_key_fingerprint(api_key)
              "ak:#{::Digest::SHA256.hexdigest(api_key)[0, 8]}"
            end

            def valid_string?(value)
              value.is_a?(String) && !value.strip.empty?
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = uri.host || 'api.openai.com'
              port = uri.port
              "#{host}:#{port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, handled: true, operation: 'openai.actor.extract_host_port',
                                  url: url.to_s)
              'api.openai.com:443'
            end

            def api_base_for(instance_cfg)
              instance_cfg[:openai_api_base] || instance_cfg[:endpoint] || 'https://api.openai.com'
            end

            # -- Graceful shutdown -------------------------------------------------

            def remove_all_instances
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token]
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'openai.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end

            # -- HTTP connections --------------------------------------------------

            def build_api_connection(instance_cfg:)
              require 'faraday'
              base_url = api_base_for(instance_cfg)
              api_key  = instance_cfg[:openai_api_key] || instance_cfg[:api_key]
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
                apply_auth_headers(f, api_key: api_key, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def apply_auth_headers(conn, api_key:, instance_cfg:)
              conn.headers['Authorization'] = "Bearer #{api_key}" if api_key
              org = instance_cfg[:openai_organization_id]
              conn.headers['OpenAI-Organization'] = org if org
              proj = instance_cfg[:openai_project_id]
              conn.headers['OpenAI-Project'] = proj if proj
            end
          end
        end
      end
    end
  end
end
