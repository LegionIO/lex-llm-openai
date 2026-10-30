# frozen_string_literal: true

require 'net/http'
require 'timeout'
require 'uri'
require 'legion/json'
require 'legion/logging'
require_relative 'error'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # Performs bounded OAuth exchanges with system-trusted TLS and no transport retries.
          class OAuthHttp
            ORIGIN = 'https://auth.openai.com'
            PATHS = %w[/oauth/token /api/accounts/deviceauth/usercode /api/accounts/deviceauth/token].freeze
            MAX_BODY_BYTES = 262_144

            def post(path:, body:, form:, timeout:)
              raise ArgumentError, 'Unsupported OAuth endpoint' unless PATHS.include?(path)

              uri = URI("#{ORIGIN}#{path}")
              request = build_request(uri: uri, body: body, form: form)
              connection = timed_connection(uri: uri, timeout: timeout)
              status, response_body = Timeout.timeout(timeout) do
                perform_request(connection: connection, request: request)
              end
              [status, parse_body(body: response_body, status: status)]
            rescue Timeout::Error
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT OAuth request timed out', kind: :timeout
              ), cause: nil
            rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
                   Net::HTTPBadResponse, Net::ProtocolError
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT OAuth connection failed; verify connectivity and certificate trust',
                kind: :connection_failure
              ), cause: nil
            end

            private

            def build_request(uri:, body:, form:)
              request = Net::HTTP::Post.new(uri.request_uri)
              request['Content-Type'] = form ? 'application/x-www-form-urlencoded' : 'application/json'
              request['Accept'] = 'application/json'
              request['User-Agent'] = 'Legion/ChatGPT'
              request['originator'] = 'legion'
              request.body = form ? URI.encode_www_form(body) : Legion::JSON.dump(body)
              request
            end

            def timed_connection(uri:, timeout:)
              connection = build_connection(uri: uri)
              connection.open_timeout = timeout
              connection.read_timeout = timeout
              connection.write_timeout = timeout
              connection.max_retries = 0
              connection
            end

            def perform_request(connection:, request:)
              status = nil
              body = +''
              connection.start do |http|
                http.request(request) do |response|
                  status = response.code.to_i
                  response.read_body { |chunk| append_body(body: body, chunk: chunk) }
                end
              end
              [status, body]
            end

            def append_body(body:, chunk:)
              if body.bytesize + chunk.bytesize > MAX_BODY_BYTES
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT OAuth response exceeded the size limit', kind: :malformed_output
                ), cause: nil
              end
              body << chunk
            end

            def build_connection(uri:)
              connection = Net::HTTP.new(uri.host, uri.port)
              connection.use_ssl = true
              # Net::HTTP verifies certificates and hostname using the system trust store.
              # Never install body/header logging or an insecure TLS override here.
              connection
            end

            def parse_body(body:, status:)
              return {} if body.empty? && !status.between?(200, 299)

              parsed = Legion::JSON.load(body)
              return parsed if parsed.is_a?(Hash)
              return {} unless status.between?(200, 299)

              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT OAuth returned an invalid response', kind: :malformed_output
              ), cause: nil
            rescue Legion::JSON::ParseError
              if status.between?(200, 299)
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT OAuth returned invalid JSON', kind: :malformed_output
                ), cause: nil
              end

              Legion::Logging.debug('ChatGPT OAuth rejected a request with a non-JSON error body')
              {}
            end
          end
        end
      end
    end
  end
end
