# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'legion/logging'
require 'legion/extensions/llm/credential_sources'
require_relative 'credential_store'
require_relative 'oauth_http'
require_relative 'browser_callback'
require_relative 'token_bundle'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # Coordinates interactive login and refresh while exposing only token-free status.
          module Auth
            SCOPE = 'openid profile email offline_access'
            AUTHORIZE_URL = 'https://auth.openai.com/oauth/authorize'
            DEVICE_URL = 'https://auth.openai.com/codex/device'
            DEVICE_REDIRECT_URI = 'https://auth.openai.com/deviceauth/callback'
            REFRESH_MARGIN = 60
            DEFAULT_TIMEOUT = 600
            MAX_TIMEOUT = 1800
            REVOKED_GRANTS = %w[invalid_grant invalid_token token_revoked refresh_token_reused refresh_token_expired
                                refresh_token_invalidated].freeze

            class << self
              def login(instance:, device: false, timeout: DEFAULT_TIMEOUT, cancelled: nil, **dependencies, &progress)
                validate_login_dependencies!(dependencies: dependencies)

                deadline = login_deadline(timeout: timeout, cancelled: cancelled)
                store = dependencies[:store] || Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore.new
                http = dependencies[:http] || Legion::Extensions::Llm::Openai::Chatgpt::OAuthHttp.new
                check = -> { check_deadline(deadline: deadline, cancelled: cancelled) }
                generation = store.begin_login(instance: instance, check: check)
                bundle = if device
                           device_login(http: http, deadline: deadline, cancelled: cancelled, &progress)
                         else
                           browser_login(http: http, deadline: deadline, cancelled: cancelled, &progress)
                         end
                check_deadline(deadline: deadline, cancelled: cancelled)
                record = store.complete_login(instance: instance, generation: generation, bundle: bundle, check: check)
                safe_status(instance: instance, record: record)
              end

              def status(instance:, store: nil)
                store ||= Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore.new
                safe_status(instance: instance, record: store.read(instance: instance))
              end

              def logout(instance:, store: nil)
                store ||= Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore.new
                store.logout(instance: instance)
                safe_status(instance: instance, record: nil)
              end

              def instances(store: nil)
                store ||= Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore.new
                store.records.to_h do |instance, record|
                  [instance, safe_status(instance: instance, record: record)]
                end
              end

              # Internal only: never publish this return value into settings, inventory or fleet.
              def credentials(instance:, expected_account_id:, expected_workspace_id:, store: nil, http: nil)
                store ||= Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore.new
                http ||= Legion::Extensions::Llm::Openai::Chatgpt::OAuthHttp.new
                store.refresh_credentials(instance: instance) do |bundle|
                  validate_binding(bundle: bundle, account_id: expected_account_id, workspace_id: expected_workspace_id)
                  next bundle if bundle[:expires_at] > Time.now.to_f + REFRESH_MARGIN

                  refresh_bundle(http: http, bundle: bundle)
                end
              end

              private

              def oauth_client_id
                Legion::Extensions::Llm::CredentialSources.setting(:extensions, :llm, :openai, :chatgpt, :client_id) ||
                  Legion::Extensions::Llm::Openai.default_settings.dig(:chatgpt, :client_id)
              end

              def validate_login_dependencies!(dependencies:)
                return if (dependencies.keys - %i[store http]).empty?

                raise ArgumentError, 'Unsupported ChatGPT login dependency'
              end

              def validate_binding(bundle:, account_id:, workspace_id:)
                return if bundle[:account_id] == account_id && bundle[:workspace_id] == workspace_id

                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT saved account or workspace does not match this execution binding',
                  kind: :authentication
                ), cause: nil
              end

              def refresh_bundle(http:, bundle:)
                request = { path: '/oauth/token', form: true,
                            body: { grant_type: 'refresh_token', client_id: oauth_client_id,
                                    refresh_token: bundle[:refresh_token], scope: SCOPE } }
                response = oauth_request(http: http, request: request, deadline: monotonic_time + 15,
                                         cancelled: nil, mode: :refreshing)
                Legion::Extensions::Llm::Openai::Chatgpt::TokenBundle.from_response(
                  response: response, previous: bundle
                )
              end

              def safe_status(instance:, record:)
                state = record && record[:status]
                if state == 'authenticated'
                  state = record[:expires_at] > Time.now.to_f ? 'authenticated' : 'expired_refreshable'
                end
                { instance: instance, auth_mode: 'chatgpt', status: state || 'missing',
                  account_id: record&.dig(:account_id), workspace_id: record&.dig(:workspace_id),
                  expires_at: record&.dig(:expires_at) }
              end

              def login_deadline(timeout:, cancelled:)
                unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive? && timeout <= MAX_TIMEOUT &&
                       (cancelled.nil? || cancelled.respond_to?(:call))
                  raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                    message: 'ChatGPT login needs a timeout between zero and 1800 seconds ' \
                             'and an optional cancellation callable', kind: :invalid_request
                  ), cause: nil
                end
                deadline = monotonic_time + timeout
                check_deadline(deadline: deadline, cancelled: cancelled)
                deadline
              end

              def monotonic_time
                ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
              end

              def check_deadline(deadline:, cancelled:)
                if cancelled&.call
                  raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                    message: 'ChatGPT login was cancelled', kind: :cancelled
                  ), cause: nil
                end
                return if monotonic_time < deadline

                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT authentication timed out; try again', kind: :timeout
                ), cause: nil
              end

              def browser_login(http:, deadline:, cancelled:, &progress)
                client_id = oauth_client_id
                listener = Legion::Extensions::Llm::Openai::Chatgpt::BrowserCallback.new
                verifier = SecureRandom.urlsafe_base64(48, false)
                state = SecureRandom.urlsafe_base64(32, false)
                url = authorization_url(verifier: verifier, state: state, client_id: client_id)
                progress&.call(status: 'authorization_required', authorization_url: url)
                code = listener.receive_code(state: state, deadline: deadline, cancelled: cancelled)
                grant = { code: code, code_verifier: verifier,
                          redirect_uri: Legion::Extensions::Llm::Openai::Chatgpt::BrowserCallback::REDIRECT_URI }
                exchange_code(http: http, grant: grant, client_id: client_id, deadline: deadline, cancelled: cancelled)
              ensure
                listener&.close
              end

              def authorization_url(verifier:, state:, client_id:)
                challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
                query = URI.encode_www_form(
                  response_type: 'code', client_id: client_id,
                  redirect_uri: Legion::Extensions::Llm::Openai::Chatgpt::BrowserCallback::REDIRECT_URI,
                  scope: SCOPE, code_challenge: challenge, code_challenge_method: 'S256', state: state,
                  id_token_add_organizations: 'true', codex_cli_simplified_flow: 'true', originator: 'legion'
                )
                "#{AUTHORIZE_URL}?#{query}"
              end

              def device_login(http:, deadline:, cancelled:, &progress)
                client_id = oauth_client_id
                initialized = initialize_device(http: http, client_id: client_id, deadline: deadline,
                                                cancelled: cancelled)
                interval = polling_interval(value: initialized.fetch(:interval, 5))
                deadline = device_deadline(initialized: initialized, deadline: deadline)
                progress&.call(status: 'authorization_required', verification_uri: DEVICE_URL,
                               user_code: initialized[:user_code])
                polled = poll_device(http: http, initialized: initialized, interval: interval,
                                     deadline: deadline, cancelled: cancelled)
                grant = device_grant(polled: polled)
                exchange_code(http: http, grant: grant, client_id: client_id, deadline: deadline, cancelled: cancelled)
              end

              def poll_device(http:, initialized:, interval:, deadline:, cancelled:)
                request = { path: '/api/accounts/deviceauth/token', form: false,
                            body: initialized.slice(:device_auth_id, :user_code) }
                loop do
                  wait_interval(interval: interval, deadline: deadline, cancelled: cancelled)
                  polled = oauth_request(http: http, request: request, deadline: deadline,
                                         cancelled: cancelled, mode: :polling)
                  if polled[:pending]
                    interval = polling_interval(value: polled[:interval]) if polled.key?(:interval)
                    next
                  end
                  return polled
                end
              end

              def initialize_device(http:, client_id:, deadline:, cancelled:)
                request = { path: '/api/accounts/deviceauth/usercode', form: false, body: { client_id: client_id } }
                initialized = oauth_request(http: http, request: request, deadline: deadline, cancelled: cancelled)
                %i[device_auth_id user_code].each { |field| validate_oauth_string(value: initialized[field]) }
                initialized
              end

              def device_deadline(initialized:, deadline:)
                return deadline unless initialized.key?(:expires_in)

                expires_in = polling_interval(value: initialized[:expires_in])
                [deadline, monotonic_time + expires_in].min
              end

              def device_grant(polled:)
                %i[authorization_code code_verifier].each { |field| validate_oauth_string(value: polled[field]) }
                { code: polled[:authorization_code], code_verifier: polled[:code_verifier],
                  redirect_uri: DEVICE_REDIRECT_URI }
              end

              def polling_interval(value:)
                interval = value.is_a?(String) && value.match?(/\A\d+(?:\.\d+)?\z/) ? value.to_f : value
                return interval if interval.is_a?(Numeric) && interval.finite? && interval.positive?

                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT device authorization returned an invalid polling interval', kind: :malformed_output
                ), cause: nil
              end

              def wait_interval(interval:, deadline:, cancelled:)
                wake = monotonic_time + interval
                loop do
                  check_deadline(deadline: deadline, cancelled: cancelled)
                  remaining = [wake, deadline].min - monotonic_time
                  break if remaining <= 0

                  sleep([remaining, 0.1].min)
                end
                check_deadline(deadline: deadline, cancelled: cancelled)
              end

              def validate_oauth_string(value:)
                return if value.is_a?(String) && value.bytesize.between?(1, 4096) && value.match?(/\A[!-~]+\z/)

                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT authorization returned an invalid response', kind: :malformed_output
                ), cause: nil
              end

              def exchange_code(http:, grant:, client_id:, deadline:, cancelled:)
                request = { path: '/oauth/token', form: true,
                            body: { grant_type: 'authorization_code', client_id: client_id }.merge(grant) }
                response = oauth_request(http: http, request: request, deadline: deadline, cancelled: cancelled)
                Legion::Extensions::Llm::Openai::Chatgpt::TokenBundle.from_response(response: response)
              end

              def oauth_request(http:, request:, deadline:, cancelled:, mode: nil)
                check_deadline(deadline: deadline, cancelled: cancelled)
                status, response = http.post(**request, timeout: [15, deadline - monotonic_time].min)
                check_deadline(deadline: deadline, cancelled: cancelled)
                classify_response(status: status, response: response, mode: mode)
              end

              def classify_response(status:, response:, mode:)
                error_code = response[:error]
                error_code = error_code[:code] if error_code.is_a?(Hash)
                if mode == :polling
                  validate_device_authorization(error_code: error_code)
                  return { pending: true }.merge(response.slice(:interval)) if [403, 404].include?(status)
                end
                return response if status.between?(200, 299) && !response.key?(:error)

                validate_refresh_grant(status: status, error_code: error_code) if mode == :refreshing
                kind = oauth_error_kind(status: status, error_code: error_code)
                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT OAuth request failed; retry or sign in again', kind: kind,
                  metadata: { http_status: status }
                ), cause: nil
              end

              def validate_device_authorization(error_code:)
                return unless %w[access_denied authorization_declined expired_token].include?(error_code)

                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT device authorization was denied or expired; start login again', kind: :authorization
                ), cause: nil
              end

              def validate_refresh_grant(status:, error_code:)
                return unless [400, 401, 403].include?(status) && REVOKED_GRANTS.include?(error_code)

                raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(
                  message: 'ChatGPT refresh grant is no longer valid; sign in again', kind: :authentication,
                  metadata: { reauth_required: true, http_status: status }
                ), cause: nil
              end

              def oauth_error_kind(status:, error_code:)
                if %w[invalid_grant invalid_token invalid_client unauthorized_client].include?(error_code) &&
                   status < 500 && status != 429
                  return :authentication
                end
                return :authorization if error_code == 'access_denied'

                http_error_kind(status: status)
              end

              def http_error_kind(status:)
                case status
                when 401 then :authentication
                when 403 then :authorization
                when 429 then :rate_limited
                when 408, 504 then :timeout
                when 500..599 then :overloaded
                else :provider_error
                end
              end
            end
          end
        end
      end
    end
  end
end
