# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../../support/chatgpt_auth_fixture'

RSpec.describe Legion::Extensions::Llm::Openai::Chatgpt::Auth, :chatgpt_auth do
  let(:chatgpt) { Legion::Extensions::Llm::Openai::Chatgpt }

  it 'completes real loopback PKCE login and persists only a private token bundle' do
    server = with_oauth_server { |_request| [200, fixture_response] }
    progress = []
    callback = nil
    result = described_class.login(instance: 'personal', store: store, http: server.http, timeout: 5) do |event|
      progress << event
      callback = callback_thread(url: event.fetch(:authorization_url))
    end
    callback.value
    authorization = URI.decode_www_form(URI(progress.first[:authorization_url]).query).to_h
    exchanged = server.requests.pop
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(exchanged[:body][:code_verifier]), padding: false)
    expect(authorization).to include('code_challenge' => challenge, 'code_challenge_method' => 'S256',
                                     'scope' => 'openid profile email offline_access', 'originator' => 'legion')
    expect(exchanged[:body]).to include(grant_type: 'authorization_code',
                                        redirect_uri: 'http://localhost:1455/auth/callback')
    expect(result).to include(status: 'authenticated', instance: 'personal', account_id: 'fixture-account')
    expect((progress + [result]).to_s).not_to include('fixture-refresh', 'fixture-authorization-code', 'signature')
    expect(store.read(instance: 'personal')[:refresh_token]).to eq('fixture-refresh-rotated')
  end

  it 'rejects mismatched state before any code exchange and closes the callback listener' do
    server = with_oauth_server { |_request| raise 'State mismatch reached token endpoint' }
    callback = nil
    expect do
      described_class.login(instance: 'personal', store: store, http: server.http, timeout: 5) do |event|
        callback = callback_thread(url: event.fetch(:authorization_url), state: 'wrong-state')
      end
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
    callback.value
    expect(server.requests).to be_empty
    listener = TCPServer.new('127.0.0.1', 1455)
    listener.close
    expect(described_class.status(instance: 'personal', store: store)[:status]).to eq('missing')
  end

  it 'rejects a callback for a different Host instead of trusting its valid state' do
    callback = nil
    expect do
      described_class.login(instance: 'personal', store: store, timeout: 5) do |event|
        callback = callback_thread(url: event.fetch(:authorization_url), host: 'attacker.invalid:1455')
      end
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
    callback.value
  end

  it 'fails an occupied allowlisted port without offering another redirect' do
    listener = TCPServer.new('127.0.0.1', 1455)
    progress = []
    expect do
      described_class.login(instance: 'personal', store: store, timeout: 1) { |event| progress << event }
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:invalid_request) }
    expect(progress).to be_empty
  ensure
    listener&.close
  end

  it 'honors its deadline while another process owns the credential lock' do
    seed_login(store: store)
    path = File.join(credential_root, "#{Base64.urlsafe_encode64('personal', padding: false)}.lock")
    File.open(path, File::RDWR) do |lock|
      lock.flock(File::LOCK_EX)
      expect do
        Timeout.timeout(2) { described_class.login(instance: 'personal', store: store, device: true, timeout: 0.02) }
      end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:timeout) }
    end
  end

  it 'does not commit a cancelled login waiting behind a rotating credential writer' do
    cancelled = false
    path = File.join(credential_root, "#{Base64.urlsafe_encode64('personal', padding: false)}.lock")
    File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
      server = with_oauth_server do |_request|
        lock.flock(File::LOCK_EX)
        [200, fixture_response]
      end
      allow(store).to receive(:complete_login).and_wrap_original do |commit, **kwargs|
        cancelled = true
        commit.call(**kwargs)
      end
      callback = nil
      expect do
        Timeout.timeout(2) do
          described_class.login(instance: 'personal', store: store, http: server.http,
                                cancelled: -> { cancelled }) do |event|
            callback = callback_thread(url: event.fetch(:authorization_url))
          end
        end
      end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:cancelled) }
      callback.value
    end
    expect(described_class.instances(store: store)).to be_empty
  end

  it 'honors device pending statuses and provider-directed intervals before exchanging the code' do
    poll_times = []
    server = with_oauth_server do |request|
      case request[:path]
      when '/api/accounts/deviceauth/usercode'
        [200, { device_auth_id: 'fixture-device', user_code: 'FIXTURE-CODE', interval: '0.02' }]
      when '/api/accounts/deviceauth/token'
        poll_times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        case poll_times.size
        when 1 then [403, { interval: 0.04 }]
        when 2 then [404, {}]
        else [200, { authorization_code: 'fixture-device-code', code_verifier: 'fixture-verifier' }]
        end
      when '/oauth/token' then [200, fixture_response]
      end
    end
    progress = []
    result = described_class.login(instance: 'personal', device: true, store: store,
                                   http: server.http, timeout: 5) { |event| progress << event }
    expect(result[:status]).to eq('authenticated')
    expect(progress).to eq([{ status: 'authorization_required',
                              verification_uri: 'https://auth.openai.com/codex/device', user_code: 'FIXTURE-CODE' }])
    expect(poll_times[1] - poll_times[0]).to be >= 0.04
    expect(poll_times[2] - poll_times[1]).to be >= 0.04
  end

  it 'treats an explicit device denial as final even on the pending HTTP status' do
    server = with_oauth_server do |request|
      if request[:path].end_with?('usercode')
        [200,
         { device_auth_id: 'fixture-device', user_code: 'FIXTURE',
           interval: 0.01 }]
      else
        [403, { error: 'access_denied', error_description: 'fixture-secret-must-not-escape' }]
      end
    end
    expect do
      described_class.login(instance: 'personal', device: true, store: store, http: server.http, timeout: 1)
    end.to(raise_error(chatgpt::Error) do |error|
      expect(error.kind).to eq(:authorization)
      expect(error.message).not_to include('fixture-secret')
      expect(error.cause).to be_nil
    end)
    expect(described_class.instances(store: store)).to be_empty
  end

  it 'does not treat device initialization 403 as pending' do
    server = with_oauth_server { |_request| [403, { error: 'access_denied' }] }
    expect do
      described_class.login(instance: 'personal', device: true, store: store, http: server.http, timeout: 1)
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:authorization) }
    expect(server.requests.size).to eq(1)
  end

  it 'bounds pending device authorization and permits cancellation during polling' do
    server = with_oauth_server do |_request|
      [200, { device_auth_id: 'fixture-device', user_code: 'FIXTURE', interval: 10 }]
    end
    expect do
      described_class.login(instance: 'personal', device: true, store: store, http: server.http, timeout: 0.05)
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:timeout) }
    cancelled = false
    expect do
      described_class.login(instance: 'personal', device: true, store: store, http: server.http, timeout: 1,
                            cancelled: -> { cancelled }) { |_event| cancelled = true }
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:cancelled) }
  end

  it 'invalidates an in-flight browser login when the same instance is disconnected' do
    server = with_oauth_server { |_request| [200, fixture_response] }
    callback = nil
    expect do
      described_class.login(instance: 'personal', store: store, http: server.http, timeout: 5) do |event|
        described_class.logout(instance: 'personal', store: store)
        callback = callback_thread(url: event.fetch(:authorization_url))
      end
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
    callback.value
    expect(described_class.status(instance: 'personal', store: store)[:status]).to eq('missing')
    expect(store.read(instance: 'personal')).not_to have_key(:access_token)
  end

  it 'preserves omitted refresh identity and refuses an execution binding with a different workspace' do
    seed_login(store: store, expires_at: 1, workspace: 'fixture-workspace', residency: 'us')
    server = with_oauth_server { |_request| [200, fixture_response(omit_identity: true)] }
    credentials = described_class.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                              expected_workspace_id: 'fixture-workspace',
                                              store: store, http: server.http)
    expect(credentials).to include(workspace_id: 'fixture-workspace', residency: 'us',
                                   refresh_token: 'fixture-refresh-rotated')
    expect do
      described_class.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                  expected_workspace_id: nil, store: store)
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
  end

  it 'marks contradictory refreshed identity for reauthentication without rebinding the account' do
    seed_login(store: store, expires_at: 1)
    server = with_oauth_server { |_request| [200, fixture_response(account: 'different-fixture-account')] }
    expect do
      described_class.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                  expected_workspace_id: nil, store: store, http: server.http)
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
    expect(described_class.status(instance: 'personal',
                                  store: store)).to include(
                                    status: 'reauth_required', account_id: 'fixture-account'
                                  )
    expect(store.read(instance: 'personal')).not_to have_key(:refresh_token)
  end

  it 'retains durable credentials after a transient refresh error but removes an invalid grant' do
    seed_login(store: store, expires_at: 1)
    response = [503, { error: 'temporarily_unavailable', error_description: 'fixture-secret' }]
    server = with_oauth_server { |_request| response }
    expect do
      described_class.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                  expected_workspace_id: nil, store: store, http: server.http)
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:overloaded) }
    expect(store.read(instance: 'personal')[:refresh_token]).to eq('fixture-refresh-original')
    response = [400, { error: 'invalid_grant', error_description: 'fixture-secret' }]
    expect do
      described_class.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                  expected_workspace_id: nil, store: store, http: server.http)
    end.to(raise_error(chatgpt::Error) do |error|
      expect(error.kind).to eq(:authentication)
      expect(error.cause).to be_nil
      expect(error.message).not_to include('fixture-secret')
    end)
    expect(described_class.status(instance: 'personal', store: store)[:status]).to eq('reauth_required')
  end

  it 'rejects invalid exchange expiry before storing a login' do
    response = fixture_response.merge(expires_in: 0)
    server = with_oauth_server { |_request| [200, response] }
    callback = nil
    expect do
      described_class.login(instance: 'personal', store: store, http: server.http, timeout: 5) do |event|
        callback = callback_thread(url: event.fetch(:authorization_url))
      end
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:malformed_output) }
    callback.value
    expect(described_class.instances(store: store)).to be_empty
  end

  it 'reports persistence failure after rotation instead of returning a successful bundle' do
    seed_login(store: store, expires_at: 1)
    server = with_oauth_server do |_request|
      File.chmod(0o500, credential_root)
      [200, fixture_response]
    end
    expect do
      described_class.credentials(instance: 'personal', expected_account_id: 'fixture-account',
                                  expected_workspace_id: nil, store: store, http: server.http)
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:provider_error) }
  ensure
    File.chmod(0o700, credential_root)
  end

  it 'expires a partial callback request without waiting indefinitely for its headers' do
    socket = nil
    expect do
      described_class.login(instance: 'personal', store: store, timeout: 0.05) do |_event|
        socket = TCPSocket.new('127.0.0.1', 1455)
        socket.write("GET /auth/callback?state=partial HTTP/1.1\r\n")
      end
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:timeout) }
  ensure
    socket&.close
  end

  it 'does not accept an already consumed state in a subsequent login' do
    server = with_oauth_server { |_request| [200, fixture_response] }
    used_state = nil
    callback = nil
    described_class.login(instance: 'personal', store: store, http: server.http, timeout: 5) do |event|
      url = event.fetch(:authorization_url)
      used_state = URI.decode_www_form(URI(url).query).to_h.fetch('state')
      callback = callback_thread(url: url)
    end
    callback.value
    expect do
      described_class.login(instance: 'personal', store: store, http: server.http, timeout: 5) do |event|
        callback = callback_thread(url: event.fetch(:authorization_url), state: used_state)
      end
    end.to raise_error(chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
    callback.value
    expect(server.requests.size).to eq(1)
  end

  it 'discards parser exceptions that could contain token response bodies' do
    server = with_oauth_server { |_request| [200, '{"access_token":"fixture-secret",'] }
    callback = nil
    expect do
      described_class.login(instance: 'personal', store: store, http: server.http, timeout: 5) do |event|
        callback = callback_thread(url: event.fetch(:authorization_url))
      end
    end.to(raise_error(chatgpt::Error) do |error|
      expect(error.kind).to eq(:malformed_output)
      expect(error.cause).to be_nil
      expect(error.full_message).not_to include('fixture-secret')
    end)
    callback.value
    expect(described_class.instances(store: store)).to be_empty
  end
end
