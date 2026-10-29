# frozen_string_literal: true

require 'faraday'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/openai/instance_discovery'
require 'legion/extensions/llm/openai/provider'
require 'legion/extensions/llm/openai/chatgpt/provider'

module Legion
  module Extensions
    module Llm
      module Openai
        module Helpers
          # Callable wrapper for an OpenAI provider instance. Implements the
          # fleet dispatch operations by delegating to the per-instance
          # Openai::Provider (errors propagate so normalize_dispatch_error can
          # classify them), plus the `disconnect` and `normalize_dispatch_error
          # (error:)` contracts required by Inventory::CallableHandle and
          # Routing::ProviderOutcome.
          #
          # Defined in its own file so the actor's runtime guard (the Every base
          # is absent in a standalone load) does not prevent specs from loading it.
          class Callable
            # Keys the base Provider exposes as named kwargs for the
            # completion operations. Anything else the fleet passes (sampling
            # scalars, `temperature` — a Canonical::Params member, 05 O4) is
            # folded into Canonical::Params at the dispatch boundary.
            COMPLETION_NAMED_KEYS = %i[tools schema thinking tool_prefs headers].freeze
            EMBED_NAMED_KEYS = %i[dimensions headers].freeze

            def initialize(instance_cfg:, logger:, provider: nil)
              normalized = Legion::Extensions::Llm::Openai::InstanceDiscovery.normalize_instance_config(instance_cfg)
              @instance_cfg = normalized.transform_values do |value|
                value.is_a?(String) ? value.dup.freeze : value
              end.freeze
              @provider_class = if @instance_cfg[:auth_mode] == :chatgpt
                                  Legion::Extensions::Llm::Openai::Chatgpt::Provider
                                else
                                  Legion::Extensions::Llm::Openai::Provider
                                end
              @logger = logger
              @injected_provider = provider
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @provider&.disconnect
              @logger.debug { '[openai][callable] disconnected' }
            end

            def provider
              @provider ||= @injected_provider || @provider_class.new(@instance_cfg)
            end

            # -- Fleet dispatch operations ----------------------------------------
            # The fleet passes `model:` as the offering's raw model id (String).
            # B4: the callable hands it to the wire unchanged — no wrapping, no
            # default, no fallback. The 0.8.0 funnel renders `model:` verbatim
            # into the payload, so a wrapped value would corrupt the request.

            def chat(messages, model:, **rest)
              # Canonical boundary (N x N law): pipeline dispatch delivers
              # Canonical::Message objects only. Hash/legacy shapes are the
              # bypass class — reject loudly, never coerce.
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.chat(messages, model: model, params: canonical_params(params), **named)
            end

            def stream_chat(messages, model:, **rest, &)
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.stream_chat(messages, model: model, params: canonical_params(params), **named, &)
            end

            def embed(text:, model:, **rest)
              named, params = split_fleet_kwargs(rest, EMBED_NAMED_KEYS)
              provider.embed(text: text, model: model, params: params, **named)
            end

            def count_tokens(messages:, model:, **rest)
              provider.enforce_canonical_messages!(messages)
              _named, params = split_fleet_kwargs(rest, [])
              provider.count_tokens(messages: messages, model: model, params: params)
            end

            def image(prompt:, model:, **rest)
              provider.image(prompt: prompt, model: model, **rest)
            end

            def moderate(input:, model:, **rest)
              provider.moderate(input: input, model: model, **rest)
            end

            def normalize_dispatch_error(error:)
              if error.is_a?(Legion::Extensions::Llm::Openai::Chatgpt::Error)
                return normalize_chatgpt_error(error: error)
              end

              reason = error.message.to_s[0, 512]

              kind = classify_api_error(error: error)

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def classify_api_error(error:)
              case error
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
              else
                # API failures do not establish authoritative instance unavailability.
                :provider_error
              end
            end

            def normalize_chatgpt_error(error:)
              if error.kind == :rate_limited && @instance_cfg[:auth_mode] == :chatgpt
                identity = Legion::JSON.dump([@instance_cfg.fetch(:account_id), @instance_cfg[:workspace_id]])
                quota_domain = Legion::Extensions::Llm::Routing::QuotaDomainKey.new(
                  provider_family: :openai, opaque_id: "chatgpt:#{::Digest::SHA256.hexdigest(identity)}"
                )
              end
              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: error.kind, reason: error.message, retry_after: error.retry_after,
                quota_domain: quota_domain, metadata: error.metadata
              )
            end

            # The 0.8.0 completion funnel receives canonical values only
            # (08 F3): the folded wire params become a Canonical::Params at
            # the dispatch boundary — temperature is a params member (05 O4),
            # never a kwarg.
            def canonical_params(params)
              Legion::Extensions::Llm::Canonical::Params.from_hash(params)
            end

            # Split the fleet's **rest into the base Provider's named kwargs
            # and a payload params hash (any passed :params merged with
            # unknown keys).
            def split_fleet_kwargs(rest, named_keys)
              named = rest.slice(*named_keys)
              extra = rest.reject { |key, _| named.key?(key) }
              params = (extra.delete(:params) || {}).to_h.merge(extra)
              [named, params]
            end

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
