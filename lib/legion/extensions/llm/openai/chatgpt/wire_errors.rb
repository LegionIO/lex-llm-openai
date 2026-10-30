# frozen_string_literal: true

require 'time'
require_relative 'error'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # Only allowlisted protocol codes and numeric quota facts leave this boundary.
          module WireErrors
            CODES = {
              'usage_limit_reached' => :rate_limited, 'rate_limit_exceeded' => :rate_limited,
              'usage_not_included' => :billing, 'turn_rate_limit_exceeded' => :rate_limited,
              'insufficient_quota' => :billing, 'billing_hard_limit_reached' => :billing,
              'invalid_api_key' => :authentication, 'token_expired' => :authentication,
              'invalid_token' => :authentication, 'account_deactivated' => :authentication,
              'permission_denied' => :authorization, 'workspace_not_authorized' => :authorization,
              'context_length_exceeded' => :context_rejected, 'model_not_found' => :model_missing,
              'model_not_ready' => :model_not_ready, 'server_overloaded' => :overloaded,
              'invalid_request_error' => :invalid_request, 'unsupported_parameter' => :invalid_request,
              'content_filter' => :safety_refusal
            }.freeze
            STATUS_KINDS = { 400 => :invalid_request, 401 => :authentication, 402 => :billing, 403 => :authorization,
                             404 => :model_missing, 408 => :timeout, 422 => :invalid_request, 429 => :rate_limited,
                             529 => :overloaded }.freeze

            module_function

            def raise_response!(status:, body:, headers: {})
              error = error_details(body: body)
              code = [error[:code], error[:type]].find { |value| CODES.key?(value) }
              kind = CODES[code] || STATUS_KINDS[status] || :provider_error
              metadata = error_metadata(status: status, code: code, error: error, headers: headers)
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                message: "ChatGPT subscription request failed (#{kind})", kind: kind,
                retry_after: quota_retry_delay(metadata: metadata, headers: headers), metadata: metadata
              ), cause: nil
            end

            def error_details(body:)
              payload = parse_body(body: body)
              payload[:error].is_a?(Hash) ? payload[:error].transform_keys(&:to_sym) : payload
            end

            def error_metadata(status:, code:, error:, headers:)
              metadata = { http_status: status }
              metadata[:code] = code if code
              %i[resets_at resets_in_seconds retry_after].each do |key|
                value = error[key]
                metadata[key] = value if value.is_a?(Numeric) && value.finite? && !value.negative?
              end
              limits = rate_limits(headers: headers)
              metadata[:rate_limits] = limits unless limits.empty?
              metadata
            end

            def quota_retry_delay(metadata:, headers:)
              retry_delay(value: headers['retry-after'] || headers['Retry-After']) ||
                metadata[:retry_after] || metadata[:resets_in_seconds] || reset_retry_delay(metadata: metadata)
            end

            def reset_retry_delay(metadata:)
              return [metadata[:resets_at] - ::Time.now.to_f, 0].max if metadata[:resets_at]

              exhausted_retry_delay(limits: metadata.fetch(:rate_limits, {}))
            end

            def exhausted_retry_delay(limits:)
              exhausted = limits.values.filter_map { |window| window[:resets_at] if window[:used_percent].to_f >= 100 }
              [exhausted.max - ::Time.now.to_f, 0].max unless exhausted.empty?
            end

            def parse_body(body:)
              parsed = body.is_a?(String) ? Legion::JSON.load(body) : body
              parsed.is_a?(Hash) ? parsed.transform_keys(&:to_sym) : {}
            rescue Legion::JSON::ParseError
              # HTTP status remains authoritative even when its optional JSON
              # error detail is absent, truncated, or replaced by an HTML proxy page.
              Legion::Logging.debug('ChatGPT returned non-JSON HTTP error details')
              {}
            end

            def rate_limits(headers:)
              %i[primary secondary].each_with_object({}) do |window, result|
                fields = { used_percent: 'used-percent', window_minutes: 'window-minutes', resets_at: 'reset-at' }
                values = fields.each_with_object({}) do |(field, suffix), parsed|
                  value = headers["x-codex-#{window}-#{suffix}"]
                  next unless value.to_s.match?(/\A\d+(?:\.\d+)?\z/)

                  number = value.to_f
                  parsed[field] = number if number.finite?
                end
                result[window] = values unless values.empty?
              end
            end

            def retry_delay(value:)
              return nil if value.nil?
              return value.to_f if value.to_s.match?(/\A\d+(?:\.\d+)?\z/) && value.to_f.finite?

              [::Time.httpdate(value.to_s).to_f - ::Time.now.to_f, 0].max
            rescue ArgumentError
              # An invalid retry hint must not replace the authoritative HTTP failure.
              Legion::Logging.debug('ChatGPT ignored an invalid Retry-After header')
              nil
            end
          end
        end
      end
    end
  end
end
