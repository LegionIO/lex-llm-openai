# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'socket'
require 'timeout'
require 'uri'
require 'base64'
require 'legion/extensions/llm/openai/chatgpt/auth'

module ChatgptAuthFixture
  attr_reader :credential_root, :store

  class LocalOAuth < Legion::Extensions::Llm::Openai::Chatgpt::OAuthHttp
    def initialize(port:)
      super()
      @port = port
    end

    private

    def build_connection(**)
      Net::HTTP.new('127.0.0.1', @port, nil)
    end
  end

  class Server
    attr_reader :requests, :http

    def initialize(&handler)
      @server = TCPServer.new('127.0.0.1', 0)
      @requests = Queue.new
      @http = ChatgptAuthFixture::LocalOAuth.new(port: @server.addr[1])
      @thread = Thread.new do
        loop do
          next unless @server.wait_readable(0.1)

          serve_request(socket: @server.accept, handler: handler)
        end
      end
      @thread.report_on_exception = false
    end

    def close
      @thread.kill
      @thread.join
      @server.close
    end

    private

    def serve_request(socket:, handler:)
      request = read_request(socket: socket)
      @requests << request
      status, response = handler.call(request)
      encoded = response.is_a?(String) ? response : Legion::JSON.dump(response)
      socket.write("HTTP/1.1 #{status} Fixture\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{encoded.bytesize}\r\nConnection: close\r\n\r\n#{encoded}")
    ensure
      socket.close
    end

    def read_request(socket:)
      request_line = socket.gets("\r\n")
      headers = read_headers(socket: socket)
      body = socket.read(headers.fetch('content-length', '0').to_i)
      payload = if headers['content-type'] == 'application/json'
                  Legion::JSON.load(body)
                else
                  URI.decode_www_form(body).to_h.transform_keys(&:to_sym)
                end
      { path: request_line.split[1], body: payload, headers: headers }
    end

    def read_headers(socket:)
      headers = {}
      while (line = socket.gets("\r\n")) != "\r\n"
        key, value = line.split(':', 2)
        headers[key.downcase] = value.strip
      end
      headers
    end
  end

  def with_oauth_server(&)
    server = ChatgptAuthFixture::Server.new(&)
    @oauth_servers ||= []
    @oauth_servers << server
    server
  end

  def fixture_token(account: 'fixture-account', workspace: nil, residency: nil, omit_identity: false)
    auth = { chatgpt_account_id: account }
    auth[:chatgpt_workspace_id] = workspace if workspace
    auth[:chatgpt_data_residency] = residency if residency
    claims = omit_identity ? {} : { 'https://api.openai.com/auth': auth }
    encoded = Base64.urlsafe_encode64(Legion::JSON.dump(claims), padding: false)
    "fixture.#{encoded}.signature"
  end

  def fixture_response(account: 'fixture-account', workspace: nil, residency: nil, omit_identity: false)
    token = fixture_token(account: account, workspace: workspace, residency: residency, omit_identity: omit_identity)
    { access_token: token, refresh_token: 'fixture-refresh-rotated', expires_in: 3600, token_type: 'Bearer' }
  end

  def seed_login(store:, instance: 'personal', expires_at: Time.now.to_f + 3600, **identity)
    raise ArgumentError, 'Unknown fixture identity field' unless (identity.keys - %i[account workspace
                                                                                     residency]).empty?

    identity = { account: 'fixture-account', workspace: nil, residency: nil }.merge(identity)
    generation = store.begin_login(instance: instance)
    token = fixture_token(**identity)
    store.complete_login(instance: instance, generation: generation,
                         bundle: { access_token: token,
                                   refresh_token: 'fixture-refresh-original', expires_at: expires_at,
                                   account_id: identity[:account], workspace_id: identity[:workspace],
                                   residency: identity[:residency] })
  end

  def callback_thread(url:, state: nil, host: 'localhost:1455', path: '/auth/callback')
    query = URI.decode_www_form(URI(url).query).to_h
    Thread.new do
      socket = TCPSocket.new('127.0.0.1', 1455)
      begin
        callback = URI.encode_www_form(state: state || query.fetch('state'), code: 'fixture-authorization-code')
        socket.write("GET #{path}?#{callback} HTTP/1.1\r\nHost: #{host}\r\n\r\n")
        socket.read
      ensure
        socket.close
      end
    end
  end
end

RSpec.configure do |config|
  config.include ChatgptAuthFixture, :chatgpt_auth
  config.around(:each, :chatgpt_auth) do |example|
    Dir.mktmpdir('legion-chatgpt-auth') do |directory|
      @credential_root = File.realpath(directory)
      @store = Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore.new(root: @credential_root)
      example.run
    ensure
      @oauth_servers&.each(&:close)
    end
  end
end
