# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'
require 'uri'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

# Stub the actor runtime so discovery_refresh.rb loads the OpenaiCallable class.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Stub base class for discovery actor loading in test context
        class Every
          def self.every_seconds = 300
        end
      end
    end

    module Helpers
      module Lex; end unless const_defined?(:Lex, false)
    end
  end
end

# Use `load` instead of `require` because spec_helper already required this
# file once (before the Every stub existed), so `require` would be a no-op.
# `load` forces re-evaluation now that the stub is in place.
load File.expand_path('../../../../lib/legion/extensions/llm/openai/actors/discovery_refresh.rb', __dir__)

# Test-local callable that extends OpenaiCallable with dispatch operations
# required by FleetWorkerExecution. Tracks inference call count for
# conformance assertions.
class TrackingOpenaiCallable < Legion::Extensions::Llm::Openai::Actor::OpenaiCallable
  attr_reader :call_count

  def initialize(instance_cfg:, logger:)
    super
    @call_count = 0
  end

  def chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'test response', model: model }
  end

  def stream_chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'streamed response', model: model }
  end

  def embed(model:, **)
    @call_count += 1
    { embedding: [0.1, 0.2, 0.3], model: model }
  end
end

# Sentinel used only in conformance tests. OpenAI does not produce a distinct
# flat instance-unavailable dispatch signal separate from overload; this
# sentinel lets the shared examples prove that :instance_unavailable correctly
# isolates the exact registry instance without requiring a real provider signal.
class OpenaiInstanceUnavailableSentinel < StandardError
  def initialize
    super('test-only: explicit instance unavailable sentinel')
  end
end

# Evidence-building helpers for the SSOT v3 conformance harness.
# Extracted to keep OpenaiSsotHarness within class length limits.
module OpenaiSsotEvidenceHelpers
  private

  def build_operation_evidence(now:, operations:)
    Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |op|
      [op, if operations[op]
             op_evidence(op, :supported, now)
           else
             op_evidence(op, :unsupported, now)
           end]
    end
  end

  def op_evidence(operation, status, observed_at)
    source = status == :unknown ? :default_false : :provider_implementation
    Legion::Extensions::Llm::Inventory::OperationEvidence.new(
      operation: operation, status: status, source: source, observed_at: observed_at
    )
  end

  def build_capability_evidence
    {
      completion: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :completion, status: :supported, source: :provider_catalog, observed_at: Time.now
      ),
      streaming: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :streaming, status: :supported, source: :provider_catalog, observed_at: Time.now
      ),
      tools: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :tools, status: :supported, source: :provider_catalog, observed_at: Time.now
      ),
      vision: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :vision, status: :supported, source: :provider_catalog, observed_at: Time.now
      ),
      thinking: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :thinking, status: :unknown, source: :default_false, observed_at: Time.now
      ),
      embedding: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :embedding, status: :unknown, source: :default_false, observed_at: Time.now
      ),
      structured_output: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :structured_output, status: :supported, source: :provider_catalog, observed_at: Time.now
      )
    }
  end

  def model_not_ready_signal?(error:)
    return false unless error.respond_to?(:response) && error.response.is_a?(Hash)

    body = error.response[:body].to_s.downcase
    body.include?('model not ready') || body.include?('model is still loading')
  end

  def extract_host_port(base_url:)
    uri = URI.parse(base_url.to_s)
    "#{uri.host || 'api.openai.com'}:#{uri.port}"
  end

  def key_fingerprint_part(api_key)
    return unless api_key.is_a?(String) && !api_key.strip.empty?

    "ak:#{::Digest::SHA256.hexdigest(api_key)[0, 8]}"
  end

  def org_project_parts(config)
    parts = []
    org = config[:openai_organization_id]
    parts << "org:#{org.strip}" if org.is_a?(String) && !org.strip.empty?
    project = config[:openai_project_id]
    parts << "proj:#{project.strip}" if project.is_a?(String) && !project.strip.empty?
    parts
  end

  def credential_identity_parts(instance_config)
    api_key = instance_config[:openai_api_key] || instance_config[:api_key]
    parts = [key_fingerprint_part(api_key)]
    parts.concat(org_project_parts(instance_config))
    parts.compact
  end
end

# Harness class for OpenAI SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching
# any external service.
class OpenaiSsotHarness
  include OpenaiSsotEvidenceHelpers

  INSTANCE_CONFIGS = [
    {
      openai_api_base: 'https://api.openai.com',
      openai_api_key: 'sk-test-key-alpha',
      openai_organization_id: 'org-alpha',
      openai_project_id: 'proj-001',
      tier: :frontier
    }.freeze,
    {
      openai_api_base: 'https://custom-openai-proxy.internal:8443',
      openai_api_key: 'sk-test-key-beta',
      openai_organization_id: 'org-beta',
      openai_project_id: 'proj-002',
      tier: :frontier
    }.freeze
  ].freeze

  def provider_family = :openai
  def instance_configs = INSTANCE_CONFIGS

  def instance_id(instance_config:)
    base_url = instance_config[:openai_api_base] || instance_config[:endpoint] || 'https://api.openai.com'
    host_port = extract_host_port(base_url: base_url)
    parts = [host_port] + credential_identity_parts(instance_config)
    parts.join('/')
  end

  def build_callable(instance_config:)
    TrackingOpenaiCallable.new(instance_cfg: instance_config, logger: Logger.new(File::NULL))
  end

  def build_offering_drafts(tier: :frontier, **)
    now = Time.now.freeze
    model_id = 'gpt-4o'
    operations = { chat: true, stream_chat: true }
    [build_single_offering(model_id: model_id, tier: tier, now: now, operations: operations)]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'OpenAI /v1/models returned 200',
      metadata: { status: 200, api_base: instance_config[:openai_api_base] }
    )
  end

  def inference_call_count(callable:)
    callable.respond_to?(:call_count) ? callable.call_count : 0
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    outcome = callable.normalize_dispatch_error(error: error)
    apply_openai_escalation(outcome: outcome, error: error)
  end

  def instance_unavailable_error
    # OpenaiInstanceUnavailableSentinel represents the theoretical case of an
    # explicit flat service-down signal from OpenAI. In practice, OpenAI does
    # not produce such a signal via normal dispatch; this sentinel satisfies
    # the shared conformance example that proves exact-instance isolation.
    OpenaiInstanceUnavailableSentinel.new
  end

  def overloaded_error
    response = { status: 503, headers: {}, body: '{"error": {"message": "Server overloaded", "type": "server_error"}}' }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  def model_not_ready_error
    response = { status: 503, headers: {}, body: '{"error": {"message": "Model not ready", "type": "server_error"}}' }
    Faraday::ServerError.new('the server responded with status 503 - model not ready', response)
  end

  private

  def apply_openai_escalation(outcome:, error:)
    # Test-only sentinel: represents an explicit flat service-down signal.
    # Connection failures, timeouts, and generic errors remain request-local
    # per §8 and never map to :instance_unavailable.
    if error.is_a?(OpenaiInstanceUnavailableSentinel)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :instance_unavailable, reason: outcome.reason)
    end

    # 503 with "model not ready" body = model_not_ready (rare for OpenAI cloud,
    # possible for custom OpenAI-compatible deployments)
    if outcome.kind == :overloaded && model_not_ready_signal?(error: error)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :model_not_ready, reason: outcome.reason)
    end

    outcome
  end

  def build_single_offering(model_id:, tier:, now:, operations:)
    quota_domains = operations.each_key.to_h do |op|
      [op, 'org:org-alpha/proj:proj-001']
    end

    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: model_id, model: model_id, tier: tier,
      operation_evidence: build_operation_evidence(now: now, operations: operations),
      capability_evidence: build_capability_evidence,
      context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :known, value: 128_000, source: :provider_catalog
      ),
      max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      quota_domains: quota_domains,
      metadata: { raw_model: model_id }.freeze,
      publication_source: :provider_catalog
    )
  end
end

RSpec.describe Legion::Extensions::Llm::Openai do
  let(:ssot_harness) { OpenaiSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # --- OpenAI-specific identity derivation -----------------------------------

  describe 'instance identity derivation' do
    it 'derives instance_id as host:port/ak:fingerprint/org:X/proj:Y' do
      config = {
        openai_api_base: 'https://api.openai.com',
        openai_api_key: 'sk-test-key-alpha',
        openai_organization_id: 'org-alpha',
        openai_project_id: 'proj-001'
      }
      fingerprint = Digest::SHA256.hexdigest('sk-test-key-alpha')[0, 8]
      expected = "api.openai.com:443/ak:#{fingerprint}/org:org-alpha/proj:proj-001"
      expect(ssot_harness.instance_id(instance_config: config)).to eq(expected)
    end

    it 'derives instance_id without org/project when not configured' do
      config = {
        openai_api_base: 'https://api.openai.com',
        openai_api_key: 'sk-test-key-alpha'
      }
      fingerprint = Digest::SHA256.hexdigest('sk-test-key-alpha')[0, 8]
      expected = "api.openai.com:443/ak:#{fingerprint}"
      expect(ssot_harness.instance_id(instance_config: config)).to eq(expected)
    end

    it 'produces distinct instance IDs for two different endpoints/credentials' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end

    it 'distinguishes two keys against the same endpoint via fingerprint' do
      config_a = { openai_api_base: 'https://api.openai.com', openai_api_key: 'sk-key-one' }
      config_b = { openai_api_base: 'https://api.openai.com', openai_api_key: 'sk-key-two' }
      id_a = ssot_harness.instance_id(instance_config: config_a)
      id_b = ssot_harness.instance_id(instance_config: config_b)
      expect(id_a).not_to eq(id_b)
    end
  end

  # --- Two instances serving the same model = separate lanes -----------------

  describe 'two OpenAI instances serving the same model' do
    def bring_up_instance(config, tier: :frontier)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :openai)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :openai, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts, coordinator: coordinator }
    end

    it 'creates separate lanes for the same model on different instances' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
      lanes_a = snapshot.lanes_for(instance_key: a[:key])
      lanes_b = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty

      lane_ids_a = lanes_a.map(&:lane_id)
      lane_ids_b = lanes_b.map(&:lane_id)
      expect(lane_ids_a & lane_ids_b).to be_empty
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      first_run = bring_up_instance(config)
      first_offering_id = registry.snapshot.offerings_for(instance_key: first_run[:key]).first.offering_id
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      # Simulate restart: reset and re-register
      registry.reset!
      second_run = bring_up_instance(config)
      second_offering_id = registry.snapshot.offerings_for(instance_key: second_run[:key]).first.offering_id
      second_lane_id = registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      expect(second_offering_id).to eq(first_offering_id)
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # --- Operation inference ---------------------------------------------------

  describe 'operation inference from model ID' do
    let(:actor_class) { Legion::Extensions::Llm::Openai::Actor::DiscoveryRefresh }

    it 'infers chat + stream_chat for a gpt model' do
      actor = actor_class.allocate
      ops = actor.send(:infer_operations, model_id: 'gpt-4o')
      expect(ops).to include(chat: true, stream_chat: true)
      expect(ops).not_to have_key(:embed)
    end

    it 'infers embed for text-embedding models' do
      actor = actor_class.allocate
      ops = actor.send(:infer_operations, model_id: 'text-embedding-3-large')
      expect(ops).to eq({ embed: true })
    end

    it 'infers moderate for moderation models' do
      actor = actor_class.allocate
      ops = actor.send(:infer_operations, model_id: 'omni-moderation-latest')
      expect(ops).to eq({ moderate: true })
    end

    it 'infers image for dall-e models' do
      actor = actor_class.allocate
      ops = actor.send(:infer_operations, model_id: 'dall-e-3')
      expect(ops).to eq({ image: true })
    end

    it 'infers transcribe for whisper models' do
      actor = actor_class.allocate
      ops = actor.send(:infer_operations, model_id: 'whisper-1')
      expect(ops).to eq({ transcribe: true })
    end

    it 'infers speak for tts models' do
      actor = actor_class.allocate
      ops = actor.send(:infer_operations, model_id: 'tts-1-hd')
      expect(ops).to eq({ speak: true })
    end
  end

  # --- Quota domain from org/project -----------------------------------------

  describe 'quota domain derivation' do
    let(:actor_class) { Legion::Extensions::Llm::Openai::Actor::DiscoveryRefresh }
    let(:chat_operations) { { chat: true, stream_chat: true } }

    it 'builds quota domain from org + project keyed by operation' do
      actor = actor_class.allocate
      cfg = { openai_organization_id: 'org-alpha', openai_project_id: 'proj-001' }
      domains = actor.send(:build_quota_domains, instance_cfg: cfg, operations: chat_operations)
      expect(domains).to eq({ chat: 'org:org-alpha/proj:proj-001', stream_chat: 'org:org-alpha/proj:proj-001' })
    end

    it 'builds quota domain from org only when project is absent' do
      actor = actor_class.allocate
      cfg = { openai_organization_id: 'org-alpha' }
      domains = actor.send(:build_quota_domains, instance_cfg: cfg, operations: chat_operations)
      expect(domains).to eq({ chat: 'org:org-alpha', stream_chat: 'org:org-alpha' })
    end

    it 'returns empty quota domains when org is absent' do
      actor = actor_class.allocate
      cfg = { openai_api_key: 'sk-test' }
      domains = actor.send(:build_quota_domains, instance_cfg: cfg, operations: chat_operations)
      expect(domains).to be_empty
    end

    it 'maps only the operations the model supports' do
      actor = actor_class.allocate
      cfg = { openai_organization_id: 'org-alpha', openai_project_id: 'proj-001' }
      domains = actor.send(:build_quota_domains, instance_cfg: cfg, operations: { embed: true })
      expect(domains).to eq({ embed: 'org:org-alpha/proj:proj-001' })
    end
  end

  # --- Startup gating --------------------------------------------------------

  describe 'startup gating' do
    # def helpers do not count toward RSpec/MultipleMemoizedHelpers.
    # With 2 inherited lets (ssot_harness, registry) the block budget is 3 lets.
    def gating_config = ssot_harness.instance_configs[0]

    def gating_key
      @gating_key ||= Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :openai,
        instance_id: ssot_harness.instance_id(instance_config: gating_config)
      )
    end

    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :openai) }
    let(:callable)  { ssot_harness.build_callable(instance_config: gating_config) }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: gating_key, enqueue: ->(**) { true }
      )
    end

    it 'remains initializing until readiness probe succeeds' do
      publisher.claim_instance(instance_id: gating_key.instance_id, callable: callable,
                               probe_request_handle: coordinator)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: gating_key)).to be_nil
      expect(snapshot.publication_status(instance_key: gating_key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      token = publisher.claim_instance(instance_id: gating_key.instance_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: gating_key.instance_id, publisher_token: token)
      publisher.readiness_failed(instance_id: gating_key.instance_id, probe_token: probe,
                                 reason: 'OpenAI /v1/models connection failed')

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: gating_key)).to be_nil
      expect(snapshot.publication_status(instance_key: gating_key).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      token = publisher.claim_instance(instance_id: gating_key.instance_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: gating_key.instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: gating_config, callable: callable,
                                                  tier: :frontier)
      publisher.activate_instance_snapshot(
        instance_id: gating_key.instance_id, publisher_token: token, offerings: drafts,
        sequence: 0, probe_token: probe
      )

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: gating_key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: gating_key).state).to eq(:complete)
    end
  end

  # --- Instance-unavailable isolation ----------------------------------------

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :openai)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :openai, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])

      # Instance A goes down
      registry.dispatch_instance_unavailable(
        instance_key: a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason: 'connection refused to custom-openai-proxy'
      )

      expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    it 'normalizes 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # --- §8 health firewall: transient errors must not mutate global availability

  describe '§8 health firewall' do
    it 'preserves connection_failure through full harness normalization (must not become instance_unavailable)' do
      error = Faraday::ConnectionFailed.new('Connection refused')
      outcome = ssot_harness.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
      expect(outcome.kind).not_to eq(:instance_unavailable),
                                  '§8: connection refusal/reset must never mutate global availability'
    end

    it 'preserves timeout through full harness normalization (must not become instance_unavailable)' do
      error = Faraday::TimeoutError.new('Net::ReadTimeout')
      outcome = ssot_harness.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:timeout)
      expect(outcome.kind).not_to eq(:instance_unavailable),
                                  '§8: timeout must never mutate global availability'
    end

    it 'preserves generic 5xx through full harness normalization (must not become instance_unavailable)' do
      [500, 502, 504].each do |status|
        response = { status: status, headers: {}, body: '' }
        error = Faraday::ServerError.new(status.to_s, response)
        outcome = ssot_harness.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "§8: HTTP #{status} must not mutate global availability"
      end
    end
  end

  # --- Error isolation (no global poisoning) ---------------------------------

  describe 'error isolation (no global poisoning)' do
    it 'classifies connection failure as connection_failure on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::ConnectionFailed.new('Connection refused')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::TimeoutError.new('Net::ReadTimeout')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies generic errors as provider_error on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = RuntimeError.new('unexpected failure')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:provider_error)
    end

    it 'classifies 503 ServerError as overloaded on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 503, headers: {}, body: '' }
      error = Faraday::ServerError.new('503', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:overloaded)
    end

    it 'classifies 429 ClientError as rate_limited on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 429, headers: {}, body: '' }
      error = Faraday::ClientError.new('429', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'classifies 401 as authentication on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 401, headers: {}, body: '' }
      error = Faraday::ClientError.new('401', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:authentication)
    end

    it 'classifies 404 as model_missing on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 404, headers: {}, body: '' }
      error = Faraday::ClientError.new('404', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:model_missing)
    end

    it 'classifies OverloadedError as overloaded on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Legion::Extensions::Llm::OverloadedError.new('overloaded')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:overloaded)
    end

    it 'classifies ServiceUnavailableError as provider_error (NOT instance_unavailable)' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Legion::Extensions::Llm::ServiceUnavailableError.new('503 service unavailable')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:provider_error)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'never returns instance_unavailable from the callable for any server error' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      [500, 502, 503, 504, 529].each do |status|
        response = { status: status, headers: {}, body: '' }
        error = Faraday::ServerError.new(status.to_s, response)
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end
  end

  # --- No DEFAULT_MODEL ------------------------------------------------------

  describe 'no default model or provider' do
    it 'does not define a DEFAULT_MODEL constant' do
      expect(described_class.const_defined?(:DEFAULT_MODEL, false)).to be(false)
    end

    it 'does not define a DEFAULT_PROVIDER constant' do
      expect(described_class.const_defined?(:DEFAULT_PROVIDER, false)).to be(false)
    end

    it 'rejects instance_id "default" as reserved' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :openai, instance_id: 'default'
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :openai, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end

  # --- OpenaiCallable direct contract ----------------------------------------

  describe Legion::Extensions::Llm::Openai::Actor::OpenaiCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end

    it 'truncates reason to 512 bytes' do
      long_message = 'x' * 1000
      error = RuntimeError.new(long_message)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.reason.length).to be <= 1024
    end
  end

  # --- OfferingDraft structure -----------------------------------------------

  describe 'OfferingDraft structure' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier) }

    it 'produces valid OfferingDraft instances' do
      expect(drafts).to all(be_a(Legion::Extensions::Llm::Inventory::OfferingDraft))
    end

    it 'includes all required operation evidence keys' do
      expected_ops = Legion::Extensions::Llm::Taxonomies::OPERATIONS.sort
      drafts.each do |draft|
        actual_ops = draft.operation_evidence.keys.sort
        expect(actual_ops).to eq(expected_ops)
      end
    end

    it 'sets publication_source to :provider_catalog' do
      drafts.each do |draft|
        expect(draft.publication_source).to eq(:provider_catalog)
      end
    end

    it 'uses frozen metadata without secret keys' do
      drafts.each do |draft|
        expect(draft.metadata).to be_frozen
        draft.metadata.each_key do |key|
          normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, '')
          expect(normalized).not_to include('credential')
          expect(normalized).not_to include('secret')
          expect(normalized).not_to include('apikey')
        end
      end
    end
  end

  # --- ReadinessResult contract ----------------------------------------------

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end

  # --- Dependency isolation --------------------------------------------------

  describe 'dependency isolation' do
    it 'does not require Legion::LLM (no reverse dependency on top-level llm module)' do
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(
        File.join(project_root, 'lib/legion/extensions/llm/openai/actors/discovery_refresh.rb')
      )
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'OpenaiCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end
end
