# frozen_string_literal: true

require 'legion/extensions/llm/routing/provider_outcome'

module Legion
  module Extensions
    module Llm
      module Openai
        # Callable wrapper for an OpenAI provider instance. Implements the
        # `disconnect` and `normalize_dispatch_error(error:)` contracts
        # required by Inventory::CallableHandle and Routing::ProviderOutcome.
        # Defined in its own file so the actor runtime guard in
        # discovery_refresh.rb does not prevent specs from loading it.
        class OpenaiCallable
          def initialize(instance_cfg:, logger:)
            @instance_cfg = instance_cfg
            @logger = logger
            @disconnected = false
          end

          def disconnected?
            @disconnected
          end

          def disconnect
            @disconnected = true
            @logger.debug { '[openai][callable] disconnected' }
          end

          def chat(model:, **)
            raise NotImplementedError, 'dispatch through the provider adapter, not the callable directly'
          end

          def stream_chat(model:, **)
            raise NotImplementedError, 'dispatch through the provider adapter, not the callable directly'
          end

          def embed(model:, **)
            raise NotImplementedError, 'dispatch through the provider adapter, not the callable directly'
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
