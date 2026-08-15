# frozen_string_literal: true

require 'faraday'

module Legion
  module Extensions
    module Llm
      module Openai
        # HTTP connection building for DiscoveryRefresh. Readiness probing and
        # model discovery both talk to the instance's /v1/models endpoint.
        module DiscoveryTransport
          private

          def build_api_connection(instance_cfg:)
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
