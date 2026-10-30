# frozen_string_literal: true

require 'socket'
require 'uri'
require 'openssl'
require_relative 'error'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # Receives one strictly validated OAuth redirect on the fixed loopback listener.
          class BrowserCallback
            REDIRECT_URI = 'http://localhost:1455/auth/callback'
            MAX_HEADER_BYTES = 16_384
            SUCCESS_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\n" \
                               "Connection: close\r\n\r\nReturn to Legion to finish signing in.\n"

            def initialize
              @server = TCPServer.new('127.0.0.1', 1455)
            rescue Errno::EADDRINUSE
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT callback port 1455 is busy; close the other login or use device login',
                kind: :invalid_request
              ), cause: nil
            rescue SystemCallError, SocketError
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT loopback callback could not be opened; use device login', kind: :connection_failure
              ), cause: nil
            end

            def receive_code(state:, deadline:, cancelled:)
              loop do
                check_wait(deadline: deadline, cancelled: cancelled)
                next unless @server.wait_readable(0.1)

                socket = @server.accept_nonblock(exception: false)
                next if socket == :wait_readable

                begin
                  request = read_request(socket: socket, deadline: [deadline, monotonic_time + 3].min,
                                         cancelled: cancelled)
                  code = validate_request(request: request, state: state)
                  socket.write(SUCCESS_RESPONSE)
                  return code
                ensure
                  socket.close
                end
              end
            rescue IOError, SystemCallError
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT callback connection failed; start login again', kind: :connection_failure
              ), cause: nil
            ensure
              close
            end

            def close
              @server.close unless @server.closed?
            end

            private

            def monotonic_time
              ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            end

            def check_wait(deadline:, cancelled:)
              if cancelled&.call
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT login was cancelled', kind: :cancelled
                ), cause: nil
              end
              return if monotonic_time < deadline

              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT login timed out; start login again', kind: :timeout
              ), cause: nil
            end

            def read_request(socket:, deadline:, cancelled:)
              request = +''
              until request.include?("\r\n\r\n")
                check_wait(deadline: deadline, cancelled: cancelled)
                next unless socket.wait_readable(0.1)

                chunk = socket.read_nonblock(4096, exception: false)
                next if chunk == :wait_readable

                invalid_callback! if chunk.nil?
                request << chunk
                invalid_callback! if request.bytesize > MAX_HEADER_BYTES
              end
              request
            end

            def validate_request(request:, state:)
              target, lines = parse_request_head(request: request)
              validate_headers(fields: parse_headers(lines: lines))
              params = callback_params(target: target)
              validate_state(received: params['state'], expected: state)
              if params.key?('error')
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT authorization was denied; start login again', kind: :authorization
                ), cause: nil
              end
              code = params['code']
              invalid_callback! unless code.is_a?(String) && code.match?(/\A[!-~]{1,4096}\z/)
              code
            rescue URI::InvalidURIError, ArgumentError
              invalid_callback!
            end

            def parse_request_head(request:)
              headers, remainder = request.split("\r\n\r\n", 2)
              invalid_callback! unless remainder.empty? && headers.ascii_only?
              lines = headers.split("\r\n")
              invalid_callback! if lines.size > 33
              request_line = lines.shift&.match(%r{\AGET (/auth/callback\?[^[:space:]]+) HTTP/1\.1\z})
              invalid_callback! unless request_line
              [request_line[1], lines]
            end

            def parse_headers(lines:)
              lines.each_with_object({}) do |line, fields|
                key, value = line.split(':', 2)
                invalid_callback! unless key&.match?(/\A[A-Za-z0-9-]+\z/) && value && !fields.key?(key.downcase)
                fields[key.downcase] = value.strip
              end
            end

            def validate_headers(fields:)
              invalid_callback! unless fields['host'] == 'localhost:1455' && !fields.key?('transfer-encoding') &&
                                       (!fields.key?('content-length') || fields['content-length'] == '0')
            end

            def callback_params(target:)
              uri = URI.parse(target)
              validate_callback_uri(uri: uri)
              pairs = URI.decode_www_form(uri.query)
              invalid_callback! unless pairs.map(&:first).uniq.size == pairs.size
              pairs.to_h
            end

            def validate_callback_uri(uri:)
              unless uri.path == '/auth/callback' && uri.fragment.nil? && uri.host.nil? && uri.scheme.nil?
                invalid_callback!
              end
              invalid_callback! if uri.query.nil? || uri.query.match?(/%(?![0-9a-fA-F]{2})/)
            end

            def validate_state(received:, expected:)
              return if received && received.bytesize == expected.bytesize &&
                        OpenSSL.fixed_length_secure_compare(received, expected)

              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT callback state did not match; start login again', kind: :authentication
              ), cause: nil
            end

            def invalid_callback!
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: 'ChatGPT callback was invalid; start login again', kind: :authentication
              ), cause: nil
            end
          end
        end
      end
    end
  end
end
