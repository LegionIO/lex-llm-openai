# frozen_string_literal: true

require 'faraday'
require 'legion/extensions/llm/routing/provider_outcome'

module Legion
  module Extensions
    module Llm
      module Openai
        # Callable wrapper for an OpenAI provider instance. Implements the
        # fleet dispatch operations by delegating to the per-instance
        # Openai::Provider (errors propagate so normalize_dispatch_error can
        # classify them), plus the `disconnect` and `normalize_dispatch_error
        # (error:)` contracts required by Inventory::CallableHandle and
        # Routing::ProviderOutcome.
        #
        # Defined in its own file so the actor runtime guard in
        # discovery_refresh.rb does not prevent specs from loading it.
        class OpenaiCallable
          def initialize(instance_cfg:, logger:, provider: nil)
            @instance_cfg = instance_cfg
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
            @provider ||= @injected_provider || Legion::Extensions::Llm::Openai::Provider.new(@instance_cfg)
          end

          # -- Fleet dispatch operations ----------------------------------------
          # The fleet passes `model:` as a raw string (the offering's model id).
          # chat/stream_chat render paths call `model.id` (maybe_normalize_
          # temperature, render_payload), so a Model::Info is required there;
          # embed/count_tokens/image/moderate accept the value verbatim (the
          # image and moderation render paths embed `model` directly in the wire
          # payload, so wrapping those would corrupt the request body).

          def chat(messages:, model:, **rest)
            # Canonical boundary (N x N law): pipeline dispatch delivers
            # Canonical::Message objects only. Hash/legacy shapes are the
            # bypass class — reject loudly, never coerce.
            provider.enforce_canonical_messages!(messages)
            provider.chat(messages: messages, model: to_model_info(model), **rest)
          end

          def stream_chat(messages:, model:, **rest, &)
            provider.enforce_canonical_messages!(messages)
            provider.stream_chat(messages: messages, model: to_model_info(model), **rest, &)
          end

          def embed(text:, model:, **rest)
            provider.embed(text: text, model: model, **rest)
          end

          def count_tokens(messages:, model:, **rest)
            provider.enforce_canonical_messages!(messages)
            provider.count_tokens(messages: messages, model: model, **rest)
          end

          def image(prompt:, model:, **rest)
            provider.image(prompt: prompt, model: model, **rest)
          end

          def moderate(input, model:, **rest)
            provider.moderate(input, model: model, **rest)
          end

          def normalize_dispatch_error(error:)
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
                   else
                     # ServiceUnavailableError and all other error types map to
                     # :provider_error. OpenAI does not produce a distinct flat
                     # instance-down signal separate from overload; only an
                     # authoritative explicit instance_unavailable condition
                     # (which OpenAI does not emit via normal dispatch) would
                     # map to :instance_unavailable.
                     :provider_error
                   end

            Legion::Extensions::Llm::Routing::ProviderOutcome.new(
              kind: kind,
              reason: reason.empty? ? 'unknown dispatch error' : reason
            )
          end

          private

          def to_model_info(model)
            return model if model.respond_to?(:id)

            Legion::Extensions::Llm::Model::Info.new(id: model.to_s, provider: :openai)
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
