# frozen_string_literal: true

require 'uri'
require 'digest'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/openai/helpers/callable'
require 'legion/extensions/llm/openai/provider'

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

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Openai::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # ── Secondary physical id (dedup/diagnostics only) ────────────────

            def derive_physical_id(instance_cfg:)
              host_port = extract_host_port(url: catalog_base_url(instance_cfg: instance_cfg))
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
              operations = infer_operations(model_id: model_id)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(operations: operations),
                capability_evidence: build_capability_evidence(model_id: model_id),
                context_evidence: build_context_evidence(model_id: model_id, model_data: model_data),
                max_output_evidence: build_max_output_evidence(model_data: model_data),
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(model_id: model_id,
                                                                                   model_data: model_data),
                model_revision_evidence: build_model_revision_evidence(model_data: model_data),
                tokenizer_evidence: absent_value_evidence,
                quota_domains: build_quota_domains(instance_cfg: instance_cfg, operations: operations),
                metadata: build_offering_metadata(model_id: model_id, instance_key: instance_key).freeze,
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
              org = instance_cfg[:openai_organization_id]
              project = instance_cfg[:openai_project_id]
              return {} unless non_blank_string?(org)

              domain_id = non_blank_string?(project) ? "org:#{org.strip}/proj:#{project.strip}" : "org:#{org.strip}"
              operations.each_key.to_h { |op| [op, domain_id] }
            end

            def build_offering_metadata(model_id:, instance_key:)
              {
                raw_model: model_id,
                instance_id: instance_key.instance_id,
                physical_id: instance_key.physical_id
              }
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

            def build_context_evidence(model_id:, model_data:)
              ctx = model_data[:context_window] || model_data[:max_model_len]
              ctx ||= capability_entry_for(model_id)[:context_window]
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

            def build_embedding_dimensions_evidence(model_id:, model_data:)
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
