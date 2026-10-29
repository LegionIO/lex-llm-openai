# frozen_string_literal: true

require 'base64'
require 'legion/json'
require_relative 'error'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # Validates token responses and reconciles their untrusted account claims.
          module TokenBundle
            AUTH_CLAIM = :'https://api.openai.com/auth'
            IDENTITY_FIELDS = %i[account_id workspace_id residency].freeze
            CLAIM_FIELDS = { chatgpt_account_id: :account_id, chatgpt_workspace_id: :workspace_id }.freeze
            RESIDENCY_FIELDS = %i[chatgpt_data_residency chatgpt_compute_residency].freeze

            class << self
              def from_response(response:, previous: nil, now: Time.now.to_f)
                validate_response(response: response)
                access = decode_claims(token: response[:access_token])
                identity = response_identity(response: response, access: access)
                inherit_identity(identity: identity, previous: previous) if previous
                invalid_bundle! unless identity[:account_id]
                { access_token: response[:access_token], refresh_token: response[:refresh_token],
                  expires_at: token_expiry(response: response, access: access, now: now),
                  account_id: identity[:account_id], workspace_id: identity[:workspace_id],
                  residency: identity[:residency] }
              end

              private

              def validate_response(response:)
                invalid_bundle! unless response.is_a?(Hash)
                %i[access_token refresh_token].each { |field| validate_token(value: response[field]) }
                validate_expiry_duration(expiry: response[:expires_in])
                invalid_bundle! if response.key?(:token_type) && response[:token_type].to_s.downcase != 'bearer'
              end

              def validate_expiry_duration(expiry:)
                invalid_bundle! unless expiry.is_a?(Numeric) && expiry.finite? && expiry.positive?
              end

              def response_identity(response:, access:)
                id_token = response[:id_token]
                validate_token(value: id_token) unless id_token.nil?
                merge_claims(access: access, identity: id_token ? decode_claims(token: id_token) : {})
              end

              def inherit_identity(identity:, previous:)
                IDENTITY_FIELDS.each do |field|
                  if identity.key?(field) && identity[field] != previous[field]
                    raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                      message: 'ChatGPT refreshed identity conflicts with the saved login; sign in again',
                      kind: :authentication, metadata: { reauth_required: true }
                    ), cause: nil
                  end
                  identity[field] = previous[field] unless identity.key?(field)
                end
              end

              def token_expiry(response:, access:, now:)
                expires_at = now + response[:expires_in]
                return expires_at unless access.key?(:exp)

                expiry = access[:exp]
                invalid_bundle! unless expiry.is_a?(Numeric) && expiry.finite? && expiry > now
                [expires_at, expiry].min
              end

              def validate_token(value:)
                invalid_bundle! unless value.is_a?(String) && value.bytesize.between?(1, 65_536) &&
                                       value.match?(/\A[!-~]+\z/)
              end

              def decode_claims(token:)
                parts = token.split('.')
                return {} unless parts.length == 3

                payload = Base64.urlsafe_decode64(parts[1])
                claims = Legion::JSON.load(payload)
                invalid_bundle! unless claims.is_a?(Hash)
                claims
              rescue ArgumentError, Legion::JSON::ParseError
                invalid_bundle!
              end

              def merge_claims(access:, identity:)
                [access, identity].each_with_object({}) do |claims, merged|
                  auth = claims[AUTH_CLAIM]
                  next if auth.nil?

                  invalid_bundle! unless auth.is_a?(Hash)
                  merge_identity(extracted: extract_identity(auth: auth), merged: merged)
                end
              end

              def merge_identity(extracted:, merged:)
                extracted.each do |field, value|
                  validate_identity(field: field, value: value)
                  invalid_bundle! if merged.key?(field) && merged[field] != value
                  merged[field] = value
                end
              end

              def extract_identity(auth:)
                extracted = {}
                CLAIM_FIELDS.each do |source, field|
                  extracted[field] = auth[source] if auth.key?(source)
                end
                field = RESIDENCY_FIELDS.find { |candidate| auth.key?(candidate) }
                extracted[:residency] = normalize_residency(value: auth[field]) if field
                extracted
              end

              def normalize_residency(value:)
                value = value.strip if value.is_a?(String)
                value.is_a?(String) && value.casecmp?('no_constraint') ? nil : value
              end

              def validate_identity(field:, value:)
                unless value.nil? || (value.is_a?(String) && value.bytesize.between?(1, 512) &&
                                     value.match?(/\A[\w.:-]+\z/))
                  invalid_bundle!
                end
                invalid_bundle! if field == :account_id && value.nil?
              end

              def invalid_bundle!
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT token response has invalid credentials, expiry or account metadata',
                  kind: :malformed_output
                ), cause: nil
              end
            end
          end
        end
      end
    end
  end
end
