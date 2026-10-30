# frozen_string_literal: true

require 'uri'
require 'digest'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/openai/helpers/callable'
require 'legion/extensions/llm/openai/provider'
require 'legion/extensions/llm/openai/chatgpt/provider'

module Legion
  module Extensions
    module Llm
      module Openai
        module Runners
          # OpenAI discovery runner: ONLY the OpenAI-specific work. Reconcile,
          # claim, activate, probe (cadence + reactive), replace, weight
          # publication, dormant-weight tracking, and health display are all
          # mixed in from the shared Discovery::Pipeline. Weight is NOT computed
          # here — the shared WeightReconciler recomputes the write-time weight
          # from live settings at publish.
          #
          # Readiness is a non-inference /v1/models GET (not /health).
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

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

            # ── OpenAI instance-config keys / connection ──────────────────────

            def catalog_base_url(instance_cfg:)
              if instance_cfg[:auth_mode] == :chatgpt
                return Legion::Extensions::Llm::Openai::Chatgpt::Provider::DEFAULT_ENDPOINT
              end

              instance_cfg[:openai_api_base] || 'https://api.openai.com'
            end

            def auth_token(instance_cfg:)
              instance_cfg[:openai_api_key] || instance_cfg[:api_key]
            end

            # OpenAI adds optional organization / project headers beyond the
            # bearer token.
            def apply_auth_headers(faraday:, instance_cfg:)
              api_key = auth_token(instance_cfg: instance_cfg)
              faraday.headers['Authorization'] = "Bearer #{api_key}" if api_key
              org = instance_cfg[:openai_organization_id]
              faraday.headers['OpenAI-Organization'] = org if org
              proj = instance_cfg[:openai_project_id]
              faraday.headers['OpenAI-Project'] = proj if proj
            end

            def health_path = '/v1/models'

            def fetch_raw_models(instance_cfg:)
              return super unless instance_cfg[:auth_mode] == :chatgpt

              provider = Legion::Extensions::Llm::Openai::Chatgpt::Provider.new(instance_cfg)
              provider.catalog
            ensure
              provider&.disconnect
            end

            def check_health(instance_cfg:)
              return super unless instance_cfg[:auth_mode] == :chatgpt

              fetch_raw_models(instance_cfg: instance_cfg)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true,
                                                                      reason: 'ChatGPT account catalog is reachable')
            rescue Legion::Extensions::Llm::Openai::Chatgpt::Error => e
              raise unless %i[authentication authorization billing invalid_request].include?(e.kind)

              handle_exception(e, level: :warn, handled: true, operation: 'openai.runner.discovery.chatgpt_health')
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: false, reason: e.message,
                                                                      metadata: { kind: e.kind })
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Openai::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # ── Secondary physical id (dedup/diagnostics only) ────────────────

            def derive_physical_id(instance_cfg:)
              host_port = extract_host_port(url: catalog_base_url(instance_cfg: instance_cfg))
              if instance_cfg[:auth_mode] == :chatgpt
                return "#{host_port}/#{chatgpt_quota_domain(instance_cfg: instance_cfg)}"
              end

              parts = [host_port]
              parts.concat(identity_parts_for(instance_cfg: instance_cfg))
              parts.join('/')
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              "#{uri.host || 'api.openai.com'}:#{uri.port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'openai.runner.discovery.extract_host_port', url: url.to_s)
              'api.openai.com:443'
            end

            # ── Offering draft (evidence + metadata; NO weight) ───────────────

            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              tier = instance_cfg[:tier] || :frontier
              subscription = instance_cfg[:auth_mode] == :chatgpt
              operations = subscription ? { chat: true, stream_chat: true } : infer_operations(model_id: model_id)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(operations: operations),
                capability_evidence: if subscription
                                       build_chatgpt_capability_evidence(model_data: model_data)
                                     else
                                       build_capability_evidence(model_id: model_id)
                                     end,
                context_evidence: build_context_evidence(model_id: model_id, model_data: model_data,
                                                         instance_cfg: instance_cfg),
                max_output_evidence: build_max_output_evidence(model_data: model_data),
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(
                  model_id: model_id, model_data: model_data, instance_cfg: instance_cfg
                ),
                model_revision_evidence: build_model_revision_evidence(model_data: model_data),
                tokenizer_evidence: absent_value_evidence,
                quota_domains: build_quota_domains(instance_cfg: instance_cfg, operations: operations),
                metadata: build_offering_metadata(model_id: model_id, instance_key: instance_key,
                                                  instance_cfg: instance_cfg).freeze,
                publication_source: :provider_catalog
              )
            end

            private

            def identity_parts_for(instance_cfg:)
              parts = []
              api_key = auth_token(instance_cfg: instance_cfg)
              parts << api_key_fingerprint(api_key) if non_blank_string?(api_key)
              org_id = instance_cfg[:openai_organization_id]
              parts << "org:#{org_id.strip}" if non_blank_string?(org_id)
              project_id = instance_cfg[:openai_project_id]
              parts << "proj:#{project_id.strip}" if non_blank_string?(project_id)
              parts
            end

            def api_key_fingerprint(api_key)
              "ak:#{::Digest::SHA256.hexdigest(api_key)[0, 8]}"
            end

            def non_blank_string?(value)
              value.is_a?(String) && !value.strip.empty?
            end

            # Operation inference: model-id prefixes map to the operation a model
            # serves; chat models serve chat + stream_chat.
            def infer_operations(model_id:)
              id = model_id.to_s.downcase
              return { embed: true } if id.start_with?('text-embedding-')
              return { moderate: true } if id.include?('moderation')
              return { image: true } if id.match?(/^(gpt-image|dall-e)/)
              return { transcribe: true } if id.match?(/^(whisper)/)
              return { speak: true } if id.match?(/^tts/)

              { chat: true, stream_chat: true }
            end

            def build_quota_domains(instance_cfg:, operations:)
              if instance_cfg[:auth_mode] == :chatgpt
                domain_id = chatgpt_quota_domain(instance_cfg: instance_cfg)
                return operations.each_key.to_h { |op| [op, domain_id] }
              end

              org = instance_cfg[:openai_organization_id]
              project = instance_cfg[:openai_project_id]
              return {} unless non_blank_string?(org)

              domain_id = non_blank_string?(project) ? "org:#{org.strip}/proj:#{project.strip}" : "org:#{org.strip}"
              operations.each_key.to_h { |op| [op, domain_id] }
            end

            def chatgpt_quota_domain(instance_cfg:)
              identity = Legion::JSON.dump([instance_cfg.fetch(:account_id), instance_cfg[:workspace_id]])
              "chatgpt:#{::Digest::SHA256.hexdigest(identity)}"
            end

            def build_offering_metadata(model_id:, instance_key:, instance_cfg:)
              metadata = {
                raw_model: model_id,
                instance_id: instance_key.instance_id,
                physical_id: instance_key.physical_id
              }
              return metadata unless instance_cfg[:auth_mode] == :chatgpt

              metadata.merge(auth_mode: :chatgpt, account_id: instance_cfg.fetch(:account_id),
                             workspace_id: instance_cfg[:workspace_id])
            end

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
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(model_id:)
              caps = capability_entry_for(model_id)[:capabilities] || []
              result = build_standard_capability_evidence(caps)
              result[:tools] =
                cap_evidence(capability: :tools, status: tool_status_for(caps), source: tool_source_for(caps))
              result
            end

            def build_chatgpt_capability_evidence(model_data:)
              statuses = {
                completion: %i[supported provider_implementation],
                streaming: %i[supported provider_implementation],
                embedding: %i[unsupported provider_implementation],
                structured_output: %i[unsupported provider_implementation],
                vision: [chatgpt_vision_status(model_data: model_data), :provider_catalog],
                thinking: [chatgpt_thinking_status(model_data: model_data), :provider_catalog],
                tools: [chatgpt_tools_status(model_data: model_data), :provider_catalog]
              }
              statuses.to_h do |capability, (status, source)|
                source = :absent if status == :unknown
                [capability, cap_evidence(capability: capability, status: status, source: source)]
              end
            end

            def chatgpt_vision_status(model_data:)
              modalities = model_data[:input_modalities]
              return :unknown unless modalities.is_a?(Array)

              modalities.include?('image') ? :supported : :unsupported
            end

            def chatgpt_tools_status(model_data:)
              return :supported if model_data[:supports_tools] == true
              return :unsupported if model_data[:supports_tools] == false
              return :supported if model_data[:supports_parallel_tool_calls] == true

              :unknown
            end

            def chatgpt_thinking_status(model_data:)
              efforts = chatgpt_reasoning_efforts(model_data: model_data)
              return :unknown if efforts.empty?

              efforts.all?('none') ? :unsupported : :supported
            end

            def chatgpt_reasoning_efforts(model_data:)
              levels = model_data[:supported_reasoning_levels]
              efforts = if levels.is_a?(Array)
                          levels.map { |level| level.is_a?(Hash) ? level[:effort] : level }
                        else
                          [model_data[:default_reasoning_level]].compact
                        end
              efforts.all? { |effort| effort.is_a?(String) && !effort.empty? } ? efforts : []
            end

            def build_standard_capability_evidence(caps)
              STANDARD_CAPABILITY_CHECKS.to_h do |cap_sym, evidence_key|
                present = caps.include?(cap_sym)
                [evidence_key, cap_evidence(capability: evidence_key,
                                            status: present ? :supported : :unknown,
                                            source: present ? :provider_catalog : :default_false)]
              end
            end

            def tool_status_for(caps)
              caps.include?(:function_calling) || caps.include?(:tools) ? :supported : :unknown
            end

            def tool_source_for(caps)
              caps.include?(:function_calling) || caps.include?(:tools) ? :provider_catalog : :default_false
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
            end

            def build_context_evidence(model_id:, model_data:, instance_cfg:)
              ctx = model_data[:context_window] || model_data[:max_model_len]
              ctx ||= if instance_cfg[:auth_mode] == :chatgpt
                        model_data[:max_context_window]
                      else
                        capability_entry_for(model_id)[:context_window]
                      end
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: ctx,
                                                                      source: :provider_catalog)
              else
                absent_value_evidence
              end
            end

            def build_max_output_evidence(model_data:)
              max_out = model_data[:max_output_tokens] || model_data[:max_completion_tokens]
              if max_out.is_a?(Integer) && max_out.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: max_out,
                                                                      source: :provider_catalog)
              else
                absent_value_evidence
              end
            end

            def build_embedding_dimensions_evidence(model_id:, model_data:, instance_cfg:)
              return absent_value_evidence if instance_cfg[:auth_mode] == :chatgpt
              return absent_value_evidence unless model_id.to_s.start_with?('text-embedding-')

              dims = model_data[:dimensions] || model_data[:embedding_dimensions]
              valid_dims?(dims) ? dimensions_evidence(dims) : absent_value_evidence
            end

            def build_model_revision_evidence(model_data:)
              revision = model_data[:revision] || model_data[:model_revision]
              if revision.is_a?(String) && !revision.strip.empty?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: revision.strip,
                                                                      source: :provider_catalog)
              else
                absent_value_evidence
              end
            end

            def valid_dims?(dims)
              dims.is_a?(Array) && !dims.empty? && dims.all? { |d| d.is_a?(Integer) && d.positive? }
            end

            def dimensions_evidence(dims)
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: dims.uniq.sort,
                                                                    source: :provider_catalog)
            end

            def capability_entry_for(model_id)
              Legion::Extensions::Llm::Openai::Provider::CAPABILITY_MAP.each do |prefix, entry|
                return entry if model_id.to_s.start_with?(prefix)
              end
              { capabilities: %i[completion streaming], modalities_input: %w[text], modalities_output: %w[text] }
            end

            def absent_value_evidence
              @absent_value_evidence ||= Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown,
                                                                                               source: :absent)
            end
          end
        end
      end
    end
  end
end
