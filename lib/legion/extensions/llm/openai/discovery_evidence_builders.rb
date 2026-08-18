# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Openai
        # Evidence-building helpers for DiscoveryRefresh. Extracted to keep
        # the main class within Metrics/ClassLength limits.
        module DiscoveryEvidenceBuilders
          # Standard capability symbols mapped to their evidence key.
          # Reasoning maps to the :thinking evidence capability key.
          # Defined here (not on the actor class): constant lookup from a
          # module method uses this module's lexical scope, so the consumer
          # must find it here or build_offering_draft raises NameError.
          STANDARD_CAPABILITY_CHECKS = {
            completion: :completion,
            streaming: :streaming,
            vision: :vision,
            reasoning: :thinking,
            embedding: :embedding,
            structured_output: :structured_output
          }.freeze

          private

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
            result[:tools] = cap_evidence(capability: :tools,
                                          status: tool_status_for(caps),
                                          source: tool_source_for(caps))
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
            return absent_value_evidence unless model_id.start_with?('text-embedding-')

            dims = model_data[:dimensions] || model_data[:embedding_dimensions]
            valid_dims?(dims) ? dimensions_evidence(dims) : absent_value_evidence
          end

          def valid_dims?(dims)
            dims.is_a?(Array) && !dims.empty? && dims.all? { |d| d.is_a?(Integer) && d.positive? }
          end

          def dimensions_evidence(dims)
            Legion::Extensions::Llm::Inventory::ValueEvidence.new(
              status: :known, value: dims.uniq.sort, source: :provider_catalog
            )
          end

          def build_model_revision_evidence(model_data:)
            revision = model_data[:revision] || model_data[:model_revision]
            if revision.is_a?(String) && !revision.strip.empty?
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known,
                                                                    value: revision.strip,
                                                                    source: :provider_catalog)
            else
              absent_value_evidence
            end
          end

          def absent_value_evidence
            Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
          end

          def capability_entry_for(model_id)
            Legion::Extensions::Llm::Openai::Provider::CAPABILITY_MAP.each do |prefix, entry|
              return entry if model_id.start_with?(prefix)
            end
            { capabilities: %i[completion streaming],
              modalities_input: %w[text], modalities_output: %w[text] }
          end
        end
      end
    end
  end
end
