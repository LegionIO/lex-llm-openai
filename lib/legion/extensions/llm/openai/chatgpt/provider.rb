# frozen_string_literal: true

require 'legion/extensions/llm'
require_relative 'auth'
require_relative 'translator'
require_relative 'stream_decoder'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # ChatGPT OAuth never enters the public API-key provider or its dialect.
          class Provider < Legion::Extensions::Llm::Provider
            DEFAULT_ENDPOINT = 'https://chatgpt.com/backend-api/'
            CLIENT_VERSION = '0.159.0'
            ORIGINATOR = 'legion'
            MINIMUM_SHARED_VERSION = Gem::Version.new('0.8.5')
            MAX_ERROR_BYTES = 65_536
            HIDDEN_VISIBILITIES = %w[hide hidden].freeze

            class << self
              def slug = 'openai'
              def configuration_requirements = %i[instance_id account_id auth_mode]
            end

            def api_base
              DEFAULT_ENDPOINT
            end

            def headers
              {
                'OpenAI-Beta' => 'responses=experimental', 'originator' => ORIGINATOR,
                'version' => CLIENT_VERSION, 'Content-Type' => 'application/json'
              }
            end

            def catalog
              verify_transport_configuration!
              seen = {}
              catalog_rows.filter_map do |row|
                model = catalog_model(row: row)
                next unless model

                id = model[:id]
                malformed!('ChatGPT catalog contains duplicate IDs') if seen[id]
                seen[id] = true
                model
              end
            rescue Legion::JSON::ParseError, Faraday::ParsingError
              malformed!('ChatGPT catalog is not valid JSON')
            rescue Faraday::TimeoutError, Timeout::Error
              transport_error!(kind: :timeout)
            rescue Faraday::ConnectionFailed, Faraday::SSLError, SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED
              transport_error!(kind: :connection_failure)
            end

            # Called by shared HTTP middleware before its generic status mapping.
            def parse_error(response)
              return if (200..299).cover?(response.status)

              Legion::Extensions::Llm::Openai::Chatgpt::WireErrors.raise_response!(
                status: response.status, body: response_error_body(response: response),
                headers: response.respond_to?(:response_headers) ? response.response_headers : response.headers
              )
            end

            private

            def catalog_rows
              credentials = current_credentials
              response = connection.get("codex/models?client_version=#{CLIENT_VERSION}") do |request|
                request.headers.merge!(authenticated_headers(credentials: credentials, accept: 'application/json'))
              end
              parse_catalog_rows(body: response.body)
            end

            def parse_catalog_rows(body:)
              payload = Legion::JSON.load(body.is_a?(String) ? body : Legion::JSON.dump(body))
              rows = payload[:models] || payload[:data] if payload.is_a?(Hash)
              malformed!('ChatGPT catalog must contain a models or data array') unless rows.is_a?(Array)
              rows
            end

            def catalog_model(row:)
              malformed!('ChatGPT catalog model must be an object') unless row.is_a?(Hash)
              return if HIDDEN_VISIBILITIES.include?(row[:visibility])

              row.merge(id: catalog_model_id(row: row))
            end

            def catalog_model_id(row:)
              id = row[:slug] || row[:id]
              malformed!('ChatGPT catalog model has no exact ID') unless nonempty_string?(value: id)
              malformed!('ChatGPT catalog contains conflicting IDs') if row[:slug] && row[:id] && row[:slug] != row[:id]
              id
            end

            def response_error_body(response:)
              body = response.body
              return body unless body.nil? || (body.respond_to?(:empty?) && body.empty?)

              request = response.respond_to?(:request) ? response.request : response.env.request
              request&.context&.fetch(Legion::Extensions::Llm::ErrorMiddleware::STREAM_ERROR_BODY_KEY, nil)
            end

            # Called by the inherited constructor before shared Connection creation.
            def ensure_configured!
              super
              validate_identity_configuration!
              validate_workspace_configuration!
              validate_endpoint_configuration!
              @binding = configuration_binding
              # Never replay a POST after any output has escaped to the caller.
              @config.max_retries = 0
              verify_transport_configuration!
            end

            def configuration_binding
              {
                instance: config.instance_id.dup.freeze, expected_account_id: config.account_id.dup.freeze,
                expected_workspace_id: config.workspace_id&.dup&.freeze
              }.freeze
            end

            def validate_identity_configuration!
              unless config.auth_mode.to_s == 'chatgpt' && nonempty_string?(value: config.instance_id) &&
                     nonempty_string?(value: config.account_id)
                raise Legion::Extensions::Llm::ConfigurationError,
                      'ChatGPT requires its exact instance and account binding'
              end
            end

            def validate_workspace_configuration!
              return unless config.workspace_id && !nonempty_string?(value: config.workspace_id)

              raise Legion::Extensions::Llm::ConfigurationError,
                    'ChatGPT workspace identity must be a nonempty String or nil'
            end

            def validate_endpoint_configuration!
              endpoint = config.openai_api_base
              return unless endpoint
              return if endpoint.is_a?(String) && endpoint.delete_suffix('/') == DEFAULT_ENDPOINT.delete_suffix('/')

              raise Legion::Extensions::Llm::ConfigurationError, 'ChatGPT subscription endpoint cannot be overridden'
            end

            def nonempty_string?(value:)
              value.is_a?(String) && !value.empty?
            end

            def verify_transport_configuration!
              unless Gem::Version.new(Legion::Extensions::Llm::VERSION) >= MINIMUM_SHARED_VERSION
                raise Legion::Extensions::Llm::ConfigurationError, 'ChatGPT subscriptions require lex-llm >= 0.8.5'
              end
              return if Legion::Settings.dig(:extensions, :llm, :ssl, :verify) == true

              raise Legion::Extensions::Llm::ConfigurationError,
                    'ChatGPT subscriptions require extensions.llm.ssl.verify: true'
            end

            def current_credentials
              credentials = Legion::Extensions::Llm::Openai::Chatgpt::Auth.credentials(**@binding)
              unless credentials[:account_id] == @binding[:expected_account_id] &&
                     credentials[:workspace_id] == @binding[:expected_workspace_id]
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT credentials no longer match the selected account', kind: :authentication
                ), cause: nil
              end
              credentials
            end

            def authenticated_headers(credentials:, accept:, model: nil)
              values = {
                'Authorization' => "Bearer #{credentials.fetch(:access_token)}",
                'chatgpt-account-id' => credentials.fetch(:account_id), 'Accept' => accept
              }
              residency = credentials[:residency]
              values['x-openai-internal-codex-residency'] = residency if residency && residency != 'no_constraint'
              values['x-codex-routing-hint'] = "model=#{model}" if model
              if values.values.any? { |value| !value.is_a?(String) || value.match?(/[\r\n]/) }
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'Invalid subscription authentication metadata', kind: :authentication
                ), cause: nil
              end
              values
            end

            # The shared provider defines these keywords; subscriptions always use SSE.
            def render_payload(messages, tools:, model:, **controls)
              raise ArgumentError, 'missing keyword: :stream' unless controls.key?(:stream)

              controls.delete(:stream)
              verify_transport_configuration!
              @translator ||= Legion::Extensions::Llm::Openai::Chatgpt::Translator.new
              @translator.render(messages: messages, model: model, tools: tools, **controls)
            end

            def sync_response(connection, payload, additional_headers = {})
              receive_response(connection: connection, payload: payload, additional_headers: additional_headers)
            end

            # Model selection is already bound in the rendered payload.
            def stream_response(connection, payload, additional_headers = {}, **options, &)
              unknown = options.keys - [:model]
              raise ArgumentError, "unknown keywords: #{unknown.join(', ')}" unless unknown.empty?

              receive_response(connection: connection, payload: payload, additional_headers: additional_headers,
                               &)
            end

            def receive_response(connection:, payload:, additional_headers:, &callback)
              state = { error_body: +''.b }
              verify_transport_configuration!
              validate_request_headers!(additional_headers: additional_headers)
              initialize_decoder(state: state, model: payload.fetch(:model), &callback)
              response = post_response(connection: connection, payload: payload, state: state)
              finish_response(response: response, state: state)
            rescue Legion::Extensions::Llm::Openai::Chatgpt::Error, Faraday::TimeoutError, Timeout::Error,
                   Faraday::ConnectionFailed, Faraday::SSLError, SocketError,
                   Errno::ECONNRESET, Errno::ECONNREFUSED => e
              raise state[:callback_error] if state[:callback_error]

              error = normalized_transport_error(error: e)
              emit_error(error: error, &callback)
              raise error, cause: nil
            end

            def finish_response(response:, state:)
              parse_error(response)
              validate_event_stream!(headers: response.headers)
              raise state[:decoder_error] if state[:decoder_error]

              state[:decoder].finish
            end

            def validate_request_headers!(additional_headers:)
              return if additional_headers.empty?

              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'Subscription request headers cannot be overridden', kind: :invalid_request
              ), cause: nil
            end

            def initialize_decoder(state:, model:, &callback)
              state[:decoder] = Legion::Extensions::Llm::Openai::Chatgpt::StreamDecoder.new(model: model) do |chunk|
                callback&.call(chunk)
              rescue StandardError => e
                state[:callback_error] = e
                raise
              end
            end

            def post_response(connection:, payload:, state:)
              credentials = current_credentials
              connection.post('codex/responses', payload) do |request|
                request.headers.merge!(authenticated_headers(credentials: credentials, accept: 'text/event-stream',
                                                             model: payload[:model]))
                request.options.context = {
                  Legion::Extensions::Llm::ErrorMiddleware::STREAM_ERROR_BODY_KEY => state[:error_body]
                }
                request.options.on_data = proc do |bytes, _size, env|
                  consume_stream_data(bytes: bytes, env: env, state: state)
                end
              end
            end

            def consume_stream_data(bytes:, env:, state:)
              error_body = state[:error_body]
              remaining = MAX_ERROR_BYTES - error_body.bytesize
              error_body << bytes.b.byteslice(0, remaining) if remaining.positive?
              status = env&.status
              if status&.positive?
                return unless (200..299).cover?(status)

                validate_event_stream!(headers: env.response_headers)
              end
              feed_decoder(bytes: bytes, state: state) unless state[:decoder_error]
            end

            def feed_decoder(bytes:, state:)
              state[:decoder].feed(bytes: bytes)
            rescue Legion::Extensions::Llm::Openai::Chatgpt::Error => e
              raise if state[:callback_error]

              # Two-argument adapters deliver status later: classify HTTP first.
              state[:decoder_error] = e
            end

            def validate_event_stream!(headers:)
              content_type = headers['content-type'].to_s.split(';').first
              malformed!('ChatGPT did not return an event stream') unless content_type == 'text/event-stream'
            end

            def normalized_transport_error(error:)
              return error if error.is_a?(Legion::Extensions::Llm::Openai::Chatgpt::Error)

              kind = error.is_a?(Faraday::TimeoutError) || error.is_a?(Timeout::Error) ? :timeout : :connection_failure
              Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: "ChatGPT subscription transport failed (#{kind})", kind: kind
              )
            end

            def emit_error(error:, &callback)
              callback&.call(Legion::Extensions::Llm::Canonical::Chunk.error_chunk(
                error: { kind: error.kind, message: error.message }, request_id: nil,
                metadata: { retry_after: error.retry_after }.compact
              ))
            end

            def malformed!(message)
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(message: message, kind: :malformed_output),
                    cause: nil
            end

            def transport_error!(kind:)
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: "ChatGPT subscription transport failed (#{kind})", kind: kind
              ), cause: nil
            end
          end
        end
      end
    end
  end
end
