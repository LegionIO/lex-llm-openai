# frozen_string_literal: true

require 'digest'
require 'uri'

module Legion
  module Extensions
    module Llm
      module Openai
        # Secondary physical-id derivation for DiscoveryRefresh. Extracted to
        # keep the main class within Metrics limits.
        #
        # The instance IDENTITY is the operator's CONFIG NAME
        # (InstanceKey.instance_id) — the key the router uses for settings
        # lookups (instances.<name>) and per-instance tuning. The derived
        # host:port/credential-fingerprint value is the SECONDARY physical id
        # (InstanceKey.physical_id): it identifies the exact endpoint +
        # credential that can independently become unavailable, and is kept
        # for dedup and diagnostics. It is never the identity — two config
        # names pointing at the same endpoint stay distinct instances.
        module DiscoveryIdentity
          private

          def derive_physical_id(instance_cfg:)
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
            instance_cfg[:openai_api_base] || 'https://api.openai.com'
          end
        end
      end
    end
  end
end
