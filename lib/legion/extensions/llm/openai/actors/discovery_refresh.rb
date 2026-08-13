# frozen_string_literal: true

# rubocop:disable Style/OneClassPerFile

require 'digest'
require 'uri'

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

module Legion
  module Extensions
    module Llm
      module Openai
        module Actor
          # Callable wrapper for an OpenAI provider instance. Implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          # Defined outside the actor guard so specs can reference it without
          # the full LegionIO actor runtime.
          class OpenaiCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @logger.debug { '[openai][callable] disconnected' }
            end

            def chat(model:, **)
              raise NotImplementedError, 'dispatch through the provider adapter, not the callable directly'
            end

            def stream_chat(model:, **)
              raise NotImplementedError, 'dispatch through the provider adapter, not the callable directly'
            end

            def embed(model:, **)
              raise NotImplementedError, 'dispatch through the provider adapter, not the callable directly'
            end

            def normalize_dispatch_error(error:) # rubocop:disable Metrics/CyclomaticComplexity
              reason = error.message.to_s[0, 512]

              kind = case error
                     when Faraday::ConnectionFailed
                       :connection_failure
                     when Faraday::TimeoutError
                       :timeout
                     when Faraday::ClientError
                       classify_client_error(error: error)
                     when Faraday::ServerError
                       classify_server_error(error: error)
                     when Legion::Extensions::Llm::OverloadedError
                       :overloaded
                     when Legion::Extensions::Llm::ServiceUnavailableError
                       # Explicit ServiceUnavailableError from lex-llm is still
                       # NOT instance_unavailable by default. Only a confirmed
                       # flat service-down response (which OpenAI doesn't produce
                       # as a distinct signal separate from overload) would be.
                       :provider_error
                     else # rubocop:disable Lint/DuplicateBranch
                       :provider_error
                     end

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def classify_client_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else :invalid_request
              end
            end

            def classify_server_error(error:)
              # NEVER classify raw 503/529/5xx as instance_unavailable by status alone.
              # OpenAI 503 means overload/maintenance, not a permanent instance death.
              # Only an explicit flat service/instance-unavailable signal (which OpenAI
              # does not produce separately from overload) would justify instance_unavailable.
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 503, 529 then :overloaded
              else :provider_error
              end
            end
          end
        end
      end
    end
  end
end

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
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Metrics/ClassLength
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper

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

            def claim_and_activate_instance(name:, instance_cfg:) # rubocop:disable Metrics/AbcSize
              instance_id = derive_instance_id(instance_cfg: instance_cfg)
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

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: publisher_token
              )

              readiness = check_readiness(instance_cfg: instance_cfg)

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: publisher_token,
                  offerings: offerings,
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

              @instance_states[instance_id] = {
                name: name,
                instance_key: instance_key,
                instance_cfg: instance_cfg,
                callable: callable,
                probe_coordinator: probe_coordinator,
                publisher_token: publisher_token,
                sequence: 0,
                offerings: offerings
              }
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
              coordinator&.finish_probe rescue nil # rubocop:disable Style/RescueModifier
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
              coordinator&.finish_probe(request: request) rescue nil # rubocop:disable Style/RescueModifier
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
            rescue Faraday::ConnectionFailed => e
              readiness_failure(reason: "OpenAI /v1/models connection failed: #{e.message}", error: e)
            rescue Faraday::TimeoutError => e
              readiness_failure(reason: "OpenAI /v1/models timeout: #{e.message}", error: e)
            rescue StandardError => e
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

            # -- Operation evidence ------------------------------------------------

            def build_operation_evidence(operations:)
              now = Time.now.freeze
              Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |op|
                [op, if operations[op]
                       op_evidence(operation: op, status: :supported, observed_at: now)
                     else
                       op_evidence(operation: op, status: :unsupported, observed_at: now)
                     end]
              end
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation,
                status: status,
                source: source,
                observed_at: observed_at
              )
            end

            # -- Capability evidence -----------------------------------------------

            def build_capability_evidence(model_id:) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
              cap_entry = capability_entry_for(model_id)
              caps = cap_entry[:capabilities] || []

              evidence = {}
              evidence[:completion] = cap_evidence(
                capability: :completion,
                status: caps.include?(:completion) ? :supported : :unknown,
                source: caps.include?(:completion) ? :provider_catalog : :default_false
              )
              evidence[:streaming] = cap_evidence(
                capability: :streaming,
                status: caps.include?(:streaming) ? :supported : :unknown,
                source: caps.include?(:streaming) ? :provider_catalog : :default_false
              )
              evidence[:tools] = cap_evidence(
                capability: :tools,
                status: tool_status_for(caps),
                source: tool_source_for(caps)
              )
              evidence[:vision] = cap_evidence(
                capability: :vision,
                status: caps.include?(:vision) ? :supported : :unknown,
                source: caps.include?(:vision) ? :provider_catalog : :default_false
              )
              evidence[:thinking] = cap_evidence(
                capability: :thinking,
                status: caps.include?(:reasoning) ? :supported : :unknown,
                source: caps.include?(:reasoning) ? :provider_catalog : :default_false
              )
              evidence[:embedding] = cap_evidence(
                capability: :embedding,
                status: caps.include?(:embedding) ? :supported : :unknown,
                source: caps.include?(:embedding) ? :provider_catalog : :default_false
              )
              evidence[:structured_output] = cap_evidence(
                capability: :structured_output,
                status: caps.include?(:structured_output) ? :supported : :unknown,
                source: caps.include?(:structured_output) ? :provider_catalog : :default_false
              )
              evidence
            end

            def tool_status_for(caps)
              return :supported if caps.include?(:function_calling) || caps.include?(:tools)

              :unknown
            end

            def tool_source_for(caps)
              return :provider_catalog if caps.include?(:function_calling) || caps.include?(:tools)

              :default_false
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability,
                status: status,
                source: source,
                observed_at: Time.now.freeze
              )
            end

            # -- Value evidence builders -------------------------------------------

            def build_context_evidence(model_id:, model_data:)
              # Try model_data first (from API response), then fall back to CAPABILITY_MAP
              ctx = model_data[:context_window] || model_data[:max_model_len]
              ctx ||= capability_entry_for(model_id)[:context_window]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: ctx, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_max_output_evidence(model_data:)
              max_out = model_data[:max_output_tokens] || model_data[:max_completion_tokens]
              if max_out.is_a?(Integer) && max_out.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: max_out, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_embedding_dimensions_evidence(model_id:, model_data:) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
              return absent_value_evidence unless model_id.start_with?('text-embedding-')

              dims = model_data[:dimensions] || model_data[:embedding_dimensions]
              if dims.is_a?(Array) && !dims.empty? && dims.all? { |d| d.is_a?(Integer) && d.positive? }
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: dims.uniq.sort, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_model_revision_evidence(model_data:)
              revision = model_data[:revision] || model_data[:model_revision]
              if revision.is_a?(String) && !revision.strip.empty?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: revision.strip, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :unknown, source: :absent
              )
            end

            # -- Quota domain ------------------------------------------------------

            def build_quota_domains(instance_cfg:, operations:)
              org = instance_cfg[:openai_organization_id]
              project = instance_cfg[:openai_project_id]

              # OpenAI rate limits are scoped to organization/project.
              # Only declare when we have authoritative org/project identity.
              return {} unless org.is_a?(String) && !org.strip.empty?

              domain_id = if project.is_a?(String) && !project.strip.empty?
                            "org:#{org.strip}/proj:#{project.strip}"
                          else
                            "org:#{org.strip}"
                          end

              # Map each supported operation to the same quota domain.
              # OpenAI rate limits apply per-org/project across all operations.
              operations.each_key.to_h do |op|
                [op, domain_id]
              end
            end

            # -- Offering metadata -------------------------------------------------

            def build_offering_metadata(model_id:, instance_key:)
              {
                raw_model: model_id,
                instance_id: instance_key.instance_id
              }
            end

            # -- Instance ID derivation --------------------------------------------

            def derive_instance_id(instance_cfg:) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
              base_url = api_base_for(instance_cfg)
              host_port = extract_host_port(url: base_url)
              api_key = instance_cfg[:openai_api_key] || instance_cfg[:api_key]
              org_id = instance_cfg[:openai_organization_id]
              project_id = instance_cfg[:openai_project_id]

              # Build identity from endpoint + credential fingerprint + org/project
              parts = [host_port]

              if api_key.is_a?(String) && !api_key.strip.empty?
                fingerprint = ::Digest::SHA256.hexdigest(api_key)[0, 8]
                parts << "ak:#{fingerprint}"
              end

              parts << "org:#{org_id.strip}" if org_id.is_a?(String) && !org_id.strip.empty?

              parts << "proj:#{project_id.strip}" if project_id.is_a?(String) && !project_id.strip.empty?

              parts.join('/')
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = uri.host || 'api.openai.com'
              port = uri.port
              "#{host}:#{port}"
            rescue URI::InvalidURIError
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

            # -- CAPABILITY_MAP (from Provider) ------------------------------------

            def capability_entry_for(model_id)
              Legion::Extensions::Llm::Openai::Provider::CAPABILITY_MAP.each do |prefix, entry|
                return entry if model_id.start_with?(prefix)
              end

              # Unknown model - return minimal capabilities
              {
                capabilities: %i[completion streaming],
                modalities_input: %w[text],
                modalities_output: %w[text]
              }
            end

            # -- HTTP connections --------------------------------------------------

            def build_api_connection(instance_cfg:) # rubocop:disable Metrics/AbcSize
              require 'faraday'
              base_url = api_base_for(instance_cfg)
              api_key = instance_cfg[:openai_api_key] || instance_cfg[:api_key]

              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
                f.headers['Authorization'] = "Bearer #{api_key}" if api_key
                if instance_cfg[:openai_organization_id]
                  f.headers['OpenAI-Organization'] = instance_cfg[:openai_organization_id]
                end
                f.headers['OpenAI-Project'] = instance_cfg[:openai_project_id] if instance_cfg[:openai_project_id]
                f.adapter Faraday.default_adapter
              end
            end
          end
        end
      end
    end
  end
end

# rubocop:enable Style/OneClassPerFile
