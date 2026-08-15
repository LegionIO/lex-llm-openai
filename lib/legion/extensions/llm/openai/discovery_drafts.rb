# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Openai
        # OfferingDraft construction and comparison helpers for
        # DiscoveryRefresh. Extracted to keep the main class and the evidence
        # module within Metrics limits.
        module DiscoveryDrafts
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
              instance_id: instance_key.instance_id
            }
          end

          # -- Offerings change detection (D3) -----------------------------------
          # Time.now observed_at stamps in the evidence poison Data#==, so a
          # rebuilt-but-unchanged catalog would otherwise replace the snapshot
          # every tick. Compare identity/status fields only.

          def offerings_changed?(previous:, current:)
            return true unless previous.size == current.size

            # Changed when any draft has no stable counterpart in the
            # previous catalog (size mismatch or an identity/status diff).
            current.any? do |draft|
              previous.none? { |candidate| drafts_stable?(candidate, draft) }
            end
          end

          def drafts_stable?(candidate, draft)
            basic_fields_stable?(candidate, draft) &&
              evidence_maps_stable?(candidate.operation_evidence, draft.operation_evidence) &&
              evidence_maps_stable?(candidate.capability_evidence, draft.capability_evidence) &&
              value_fields_stable?(candidate, draft) &&
              candidate.quota_domains == draft.quota_domains &&
              candidate.metadata == draft.metadata
          end

          def basic_fields_stable?(candidate, draft)
            candidate.model == draft.model &&
              candidate.tier == draft.tier &&
              evidence_keys_stable?(candidate.operation_evidence, draft.operation_evidence) &&
              evidence_keys_stable?(candidate.capability_evidence, draft.capability_evidence)
          end

          def evidence_keys_stable?(previous_map, current_map)
            previous_map.keys.sort == current_map.keys.sort
          end

          def evidence_maps_stable?(previous_map, current_map)
            previous_map.all? do |key, evidence|
              other = current_map[key]
              other&.status == evidence.status && other&.source == evidence.source
            end
          end

          def value_fields_stable?(candidate, draft)
            values_stable?(candidate.context_evidence, draft.context_evidence) &&
              values_stable?(candidate.max_output_evidence, draft.max_output_evidence) &&
              values_stable?(candidate.embedding_dimensions_evidence, draft.embedding_dimensions_evidence) &&
              values_stable?(candidate.model_revision_evidence, draft.model_revision_evidence)
          end

          def values_stable?(previous_value, current_value)
            previous_value.status == current_value.status &&
              previous_value.value == current_value.value &&
              previous_value.source == current_value.source
          end
        end
      end
    end
  end
end
