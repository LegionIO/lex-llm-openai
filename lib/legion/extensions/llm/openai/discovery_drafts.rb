# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Openai
        # OfferingDraft construction and comparison helpers for
        # DiscoveryRefresh. Extracted to keep the main class and the evidence
        # module within Metrics limits.
        module DiscoveryDrafts
          EVIDENCE_MAP_FIELDS = %i[operation_evidence capability_evidence].freeze
          VALUE_EVIDENCE_FIELDS = %i[
            context_evidence max_output_evidence embedding_dimensions_evidence
            model_revision_evidence tokenizer_evidence
          ].freeze

          private

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
              instance_id: instance_key.instance_id,
              physical_id: instance_key.physical_id
            }
          end

          # -- Offerings change detection (D3) -----------------------------------
          # Time.now observed_at stamps in the evidence poison Data#==, so a
          # rebuilt-but-unchanged catalog would otherwise replace the snapshot
          # every tick. Every other OfferingDraft field is authoritative.

          def offerings_changed?(previous:, current:)
            offering_multiset(previous) != offering_multiset(current)
          end

          def offering_multiset(offerings)
            offerings.map { |draft| stable_draft_state(draft) }.tally
          end

          def stable_draft_state(draft)
            state = draft.to_h
            EVIDENCE_MAP_FIELDS.each do |field|
              state[field] = state.fetch(field).transform_values do |evidence|
                stable_evidence_state(evidence)
              end
            end
            VALUE_EVIDENCE_FIELDS.each do |field|
              state[field] = stable_evidence_state(state.fetch(field))
            end
            state
          end

          def stable_evidence_state(evidence)
            evidence.to_h.except(:observed_at)
          end
        end
      end
    end
  end
end
