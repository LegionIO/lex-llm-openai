# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'legion/crypt'
require 'legion/crypt/jwt'
require 'legion/extensions/llm/fleet/worker_execution'
require_relative '../../../../../support/chatgpt_http_fixture'

RSpec.describe Legion::Extensions::Llm::Openai::Chatgpt::Provider do
  let(:runner) { Legion::Extensions::Llm::Openai::Runners::Discovery }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:root) { File.realpath(Dir.mktmpdir('chatgpt-integration-')) }
  let(:peer) { ChatgptHttpFixture.new }
  let(:store) { Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore.new(root: root) }

  around do |example|
    saved_extensions = Legion::Settings.loader.settings[:extensions]
    saved_llm = Legion::Settings.loader.settings[:llm]
    Legion::Settings.loader.settings[:extensions] = { llm: { ssl: { verify: true }, openai: { instances: {} } } }
    Legion::Settings.loader.settings[:llm] = {}
    example.run
  ensure
    registry.reset!
    runner.reset_state!
    peer.close
    Legion::Settings.loader.settings[:extensions] = saved_extensions
    Legion::Settings.loader.settings[:llm] = saved_llm
    FileUtils.remove_entry(root)
  end

  before do
    allow(Legion::Extensions::Llm::Openai::Chatgpt::CredentialStore).to receive(:new).and_return(store)
    allow(Legion::Extensions::Llm::CredentialSources)
      .to receive_messages(env: nil, codex_openai_key: nil, claude_config_value: nil)
    allow(described_class).to receive(:new).and_wrap_original do |constructor, *args|
      provider = constructor.call(*args)
      provider.connection.connection.url_prefix = peer.url
      provider
    end
    allow(Legion::Crypt).to receive(:cluster_secret).and_return('synthetic-fleet-signing-key')
    registry.reset!
    runner.reset_state!
    Legion::Extensions::Llm::Fleet::TokenValidator.reset_replay_cache!
    Legion::Extensions::Llm::Fleet::WorkerExecution.reset_idempotency_cache!
  end

  def seed_login(instance: 'personal', account_id: 'acct-personal', access_token: 'synthetic-personal-token')
    generation = store.begin_login(instance: instance)
    store.complete_login(instance: instance, generation: generation, bundle: {
                           access_token: access_token, refresh_token: 'synthetic-refresh-token',
                           expires_at: Time.now.to_i + 3600, account_id: account_id, workspace_id: nil, residency: nil
                         })
  end

  def queue_catalog(model: 'gpt-subscription', **fields)
    body = Legion::JSON.dump({ models: [{ slug: model, context_window: 200_000, supports_tools: true }.merge(fields)] })
    2.times { peer.reply(body: body, content_type: 'application/json') }
  end

  def publish_subscription
    seed_login
    queue_catalog
    runner.reconcile_instances
    peer.requests.clear
  end

  def instance_key(name: 'personal')
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(provider_family: :openai, instance_id: name)
  end

  def lane(name: 'personal')
    registry.snapshot.lanes_for(instance_key: instance_key(name: name)).first
  end

  def with_callable(name: 'personal')
    lease = registry.acquire(callable_handle: lane(name: name).callable_handle)
    yield lease.callable
  ensure
    lease&.release
  end

  def queue_completion(text: 'subscription reply')
    event = {
      type: 'response.completed', response: {
        id: 'resp-synthetic', model: 'gpt-subscription', status: 'completed',
        output: [{
          type: 'message', id: 'msg-synthetic', role: 'assistant', content: [{ type: 'output_text', text: text }]
        }],
        usage: { input_tokens: 7, output_tokens: 3, total_tokens: 10 }
      }
    }
    peer.reply(body: "data: #{Legion::JSON.dump(event)}\n\n")
  end

  def messages
    [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')]
  end

  def signed_envelope(**overrides)
    envelope = {
      protocol_version: Legion::Extensions::Llm::Fleet::Protocol::VERSION,
      execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: lane.lane_id, provider: 'openai', provider_instance: 'personal',
      model: 'gpt-subscription', operation: 'chat',
      params: { messages: messages.map(&:to_h) }, timeout_seconds: 30, reply_to: 'fixture.reply',
      message_context: {}, caller: {}, trace_context: {}
    }.merge(request_identity).merge(overrides)
    envelope[:signed_token] = Legion::Crypt::JWT.issue(
      envelope.merge(aud: 'lex-llm-fleet-worker', nbf: Time.now.to_i),
      signing_key: 'synthetic-fleet-signing-key', issuer: 'legion-llm', ttl: 30
    )
    Legion::JSON.load(Legion::JSON.dump(envelope))
  end

  def request_identity
    {
      request_id: SecureRandom.uuid, correlation_id: SecureRandom.uuid,
      idempotency_key: SecureRandom.uuid, expires_at: (Time.now.utc + 30).iso8601
    }
  end

  it 'publishes native account models alongside an independently named API-key instance' do
    Legion::Settings[:extensions][:llm][:openai][:instances][:api] = {
      api_key: 'synthetic-api-key', openai_api_base: peer.url
    }
    api_catalog = Legion::JSON.dump({ data: [{ id: 'gpt-4o' }] })
    2.times { peer.reply(body: api_catalog, content_type: 'application/json') }
    seed_login
    queue_catalog
    runner.reconcile_instances

    expect(lane(name: 'api').model).to eq('gpt-4o')
    expect(lane.model).to eq('gpt-subscription')
    expect(registry.snapshot.instance(instance_key: instance_key).availability.state).to eq(:available)
    queue_completion
    with_callable { |callable| expect(callable.chat(messages, model: lane.model).text).to eq('subscription reply') }
    requests = Array.new(5) { peer.requests.pop }
    expect(requests.last[:headers]).to include('authorization' => 'Bearer synthetic-personal-token',
                                               'chatgpt-account-id' => 'acct-personal')
    expect(Legion::JSON.load(requests.last[:body])[:model]).to eq('gpt-subscription')
  end

  it 'keeps account catalogs separate and never fills absent evidence from the API model map' do
    seed_login
    seed_login(instance: 'work', account_id: 'acct-work', access_token: 'synthetic-work-token')
    queue_catalog(model: 'gpt-4o', context_window: nil, supports_tools: nil)
    queue_catalog(model: 'work-only')
    runner.reconcile_instances

    expect(lane.model).to eq('gpt-4o')
    expect(lane(name: 'work').model).to eq('work-only')
    expect(lane.context_evidence).to be_unknown
    expect(lane.capability_evidence.fetch(:vision)).to be_unknown
    expect(lane.capability_evidence.fetch(:tools)).to be_unknown
    expect(lane.capability_evidence.fetch(:embedding)).to be_unsupported
  end

  it 'shares account quota domains without collapsing operator instance identities' do
    seed_login
    seed_login(instance: 'mirror')
    2.times { queue_catalog }
    runner.reconcile_instances

    expect(lane.instance_key).not_to eq(lane(name: 'mirror').instance_key)
    expect(lane.quota_domain).to eq(lane(name: 'mirror').quota_domain)
    original_physical_id = registry.snapshot.instance(instance_key: instance_key).instance_key.physical_id
    seed_login(access_token: 'rotated-synthetic-token')
    2.times { queue_catalog }
    runner.reconcile_instances
    expect(registry.snapshot.instance(instance_key: instance_key).instance_key.physical_id).to eq(original_physical_id)
  end

  it 'invalidates an already constructed callable on logout without invoking another account' do
    publish_subscription
    with_callable do |callable|
      Legion::Extensions::Llm::Openai::Chatgpt::Auth.logout(instance: 'personal')
      expect { callable.chat(messages, model: 'gpt-subscription') }
        .to raise_error(Legion::Extensions::Llm::Openai::Chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
    end
    expect(peer.requests).to be_empty
  end

  it 'refuses account replacement through a previously selected callable' do
    publish_subscription
    with_callable do |callable|
      seed_login(account_id: 'acct-replacement')
      expect { callable.chat(messages, model: 'gpt-subscription') }
        .to raise_error(Legion::Extensions::Llm::Openai::Chatgpt::Error) { |error| expect(error.kind).to eq(:authentication) }
    end
    expect(peer.requests).to be_empty
  end

  it 'returns throttling to the routing owner without replay or fallback' do
    publish_subscription
    peer.reply(status: 429, content_type: 'application/json', body: '{"error":{"type":"usage_limit_reached"}}',
               headers: { 'Retry-After' => '12' })
    with_callable do |callable|
      invoke = -> { callable.chat(messages, model: 'gpt-subscription') }
      expect(&invoke).to raise_error(Legion::Extensions::Llm::Openai::Chatgpt::Error) do |error|
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).to eq(:rate_limited)
        expect(outcome.retry_after).to eq(12)
        expect(outcome.quota_domain.opaque_id).to eq(lane.quota_domain)
      end
    end
    expect(peer.requests.size).to eq(1)
  end

  it 'executes a signed JSON fleet request through exact inventory resolution and Canonical rehydration' do
    publish_subscription
    queue_completion(text: 'fleet reply')
    response = Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: signed_envelope, registry: registry)
    expect(response.text).to eq('fleet reply')
    request = peer.requests.pop
    expect(request[:headers]['chatgpt-account-id']).to eq('acct-personal')
    expect(Legion::JSON.load(request[:body])).to include(model: 'gpt-subscription')
  end

  it 'rejects altered signatures and signed model mismatches before inference HTTP' do
    publish_subscription
    altered = signed_envelope.merge(provider_instance: 'api')
    expect { Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: altered, registry: registry) }
      .to raise_error(Legion::Extensions::Llm::Fleet::WorkerExecution::PolicyError)
    wrong_model = signed_envelope(model: 'other-model')
    expect { Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: wrong_model, registry: registry) }
      .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    expect(peer.requests).to be_empty
  end
end
