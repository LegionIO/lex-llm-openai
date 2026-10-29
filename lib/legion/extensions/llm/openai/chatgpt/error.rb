# frozen_string_literal: true

require 'legion/extensions/llm/taxonomies'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # Only provider-authored messages and metadata belong here, never upstream bodies.
          class Error < StandardError
            attr_reader :kind, :retry_after, :metadata

            def initialize(message:, kind:, retry_after: nil, metadata: {})
              unless Legion::Extensions::Llm::Taxonomies::PROVIDER_OUTCOMES.include?(kind)
                raise ArgumentError, 'Unknown provider outcome kind'
              end

              @kind = kind
              @retry_after = retry_after
              @metadata = metadata.freeze
              super(message)
            end
          end
        end
      end
    end
  end
end
