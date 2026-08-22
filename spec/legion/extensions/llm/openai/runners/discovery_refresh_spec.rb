# frozen_string_literal: true

require 'digest'
require 'spec_helper'

require 'legion/extensions/llm/openai/runners/discovery'
require 'legion/extensions/llm/openai/actors/discovery'

# OpenAI discovery: ONLY the provider-owned delta is proven here. The shared
# Discovery::Pipeline behavior (claim/activation mechanics, D4 recovery,
# cadence probes, replace semantics, write-time weight publication, sequence
# monotonicity) is a shared contract — proven at the shared owner (lex-llm).
# This spec keeps:
#   * derive_physical_id — the OpenAI endpoint/credential/org/project fingerprint;
#   * build_offering_draft — the OpenAI evidence delta (CAPABILITY_MAP
#     capability + operation evidence, context evidence);
#   * config-name identity (two config names, one endpoint);
#   * first-tick activation + D14 display health/capability write-back;
#   * offering-equivalence complement (duplicate multiplicity is significant);
#   * readiness-race ownership (removal wins; activation rebuilds from
#     current settings);
#   * actor periodicity (D9).
RSpec.describe Legion::Extensions::Llm::Openai::Runners::Discovery do
  # let (not subject) so the boundary stubs below are not flagged as stubbing
  # the object under test.
  let(:runner) { described_class }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  # Legion::Settings[:extensions] is a live Concurrent::Hash; the llm/openai
  # subtrees may not exist in a fresh test process — create them in place so
  # discovery reads and D14 display writes go through the genuine settings
  # tree (same as production).
  let(:settings_tree) do
    extensions = Legion::Settings[:extensions]
    extensions[:llm] ||= {}
    extensions[:llm][:openai] ||= {}
  end

  let(:alpha_cfg) do
    {
      openai_api_base: 'https://api.openai.com',
      openai_api_key: 'sk-lifecycle-alpha',
      openai_organization_id: 'org-alpha',
      tier: :frontier
    }
  end

  before do
    registry.reset!
    # The runner module carries process-local working state (states) that
    # outlives registry.reset!; drop it for a fresh pass per example.
    runner.reset_state!
    settings_tree[:instances] = { alpha: {} }

    # Boundary stubs: the runner builds its own Faraday connections per
    # probe/fetch, so the probe + model-fetch boundary is stubbed on the
    # runner module (there is no injectable seam at the connection level).
    allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances).and_return({ alpha: alpha_cfg })
    allow(runner).to receive(:fetch_raw_models).and_return(models)
    allow(runner).to receive(:check_health) { ready_result }
  end

  after { settings_tree.clear }

  def models
    [{ id: 'gpt-4o' }, { id: 'text-embedding-3-small' }]
  end

  def ready_result
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true, reason: 'OpenAI /v1/models returned 200', metadata: { status: 200 }
    )
  end

  def readiness_result(ready:)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: ready, reason: ready ? 'ready' : 'not ready', metadata: {}
    )
  end

  # The registry key for a discovered instance: the operator's CONFIG NAME as
  # identity, the derived endpoint/credential id as the secondary physical_id.
  def key_for(cfg, name: :alpha)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :openai,
      instance_id: name.to_s,
      physical_id: runner.derive_physical_id(instance_cfg: cfg)
    )
  end

  def draft_for(model_id, cfg: alpha_cfg, name: :alpha)
    runner.build_offering_draft(
      instance_cfg: cfg,
      instance_key: key_for(cfg, name: name),
      model_id: model_id,
      model_data: { id: model_id }
    )
  end

  def full_weight_settings(provider: 100, instance: 100, model: 100, tier: 100)
    {
      extensions: {
        llm: {
          openai: {
            weight: provider,
            instances: {
              alpha: {
                weight: instance,
                models: { 'gpt-4o' => { weight: model } }
              }
            }
          }
        }
      },
      llm: { routing: { tier_weights: { frontier: tier } } }
    }
  end

  # Write-time weight publication reads live settings through
  # Legion::Settings.dig (the shared reconciler's seam); point it at a
  # per-example live tree so the activation rebuild is observable.
  def stub_live_settings(live_settings)
    allow(Legion::Settings).to receive(:dig) { |*path| live_settings.dig(*path) }
  end

  # ── derive_physical_id: OpenAI endpoint + credential + org/project ─────────
  # instance_id is the operator's config NAME; physical_id is the derived
  # host:port(/ak:<8-hex-fingerprint>/org:<org>/proj:<project>) — secondary
  # only (dedup/diagnostics), never identity.
  describe '.derive_physical_id' do
    it 'derives host:port/ak:<fingerprint>/org:<org> from the endpoint and credential' do
      fingerprint = Digest::SHA256.hexdigest('sk-lifecycle-alpha')[0, 8]
      expect(runner.derive_physical_id(instance_cfg: alpha_cfg))
        .to eq("api.openai.com:443/ak:#{fingerprint}/org:org-alpha")
    end

    it 'derives host:port/ak:<fingerprint> when org and project are unset' do
      cfg = {
        openai_api_base: 'https://beta-proxy.internal:8443',
        openai_api_key: 'sk-lifecycle-beta'
      }
      fingerprint = Digest::SHA256.hexdigest('sk-lifecycle-beta')[0, 8]
      expect(runner.derive_physical_id(instance_cfg: cfg)).to eq("beta-proxy.internal:8443/ak:#{fingerprint}")
    end

    it 'derives host:port only when the instance carries no credential' do
      expect(runner.derive_physical_id(instance_cfg: { openai_api_base: 'https://api.openai.com' }))
        .to eq('api.openai.com:443')
    end
  end

  # ── build_offering_draft: the OpenAI evidence delta ─────────────────────────
  # CAPABILITY_MAP is the single source of the per-family capability/modality/
  # context facts; the runner publishes them as evidence (weight-free — the
  # reconciler weights at publish).
  describe '.build_offering_draft' do
    it 'publishes chat + stream_chat :supported and embed :unsupported for a chat model' do
      ops = draft_for('gpt-4o').operation_evidence
      expect(ops[:chat].status).to eq(:supported)
      expect(ops[:stream_chat].status).to eq(:supported)
      expect(ops[:embed].status).to eq(:unsupported)
    end

    it 'publishes embed :supported and chat :unsupported for an embedding model' do
      ops = draft_for('text-embedding-3-small').operation_evidence
      expect(ops[:embed].status).to eq(:supported)
      expect(ops[:chat].status).to eq(:unsupported)
      expect(ops[:stream_chat].status).to eq(:unsupported)
    end

    it 'publishes the CAPABILITY_MAP capability evidence for a chat model' do
      caps = draft_for('gpt-4o').capability_evidence
      %i[completion streaming vision structured_output tools].each do |capability|
        expect(caps[capability].status).to eq(:supported)
      end
      expect(caps[:tools].source).to eq(:provider_catalog)
      expect(caps[:embedding].status).to eq(:unknown)
    end

    it 'advertises embedding only for embedding models' do
      expect(draft_for('gpt-4o').capability_evidence[:embedding].status).to eq(:unknown)
      expect(draft_for('text-embedding-3-small').capability_evidence[:embedding].status).to eq(:supported)
    end

    it 'maps the CAPABILITY_MAP context window into the context evidence' do
      gpt_context = draft_for('gpt-4o').context_evidence
      expect(gpt_context.status).to eq(:known)
      expect(gpt_context.value).to eq(128_000)
      expect(draft_for('text-embedding-3-small').context_evidence.value).to eq(8_191)
    end

    it 'carries the provider-catalog publication source and frozen secret-free metadata' do
      draft = draft_for('gpt-4o')
      expect(draft.publication_source).to eq(:provider_catalog)
      expect(draft.metadata).to be_frozen
      fingerprint = Digest::SHA256.hexdigest('sk-lifecycle-alpha')[0, 8]
      expect(draft.metadata).to eq(
        raw_model: 'gpt-4o',
        instance_id: 'alpha',
        physical_id: "api.openai.com:443/ak:#{fingerprint}/org:org-alpha"
      )
      draft.metadata.each_key do |key|
        normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, '')
        expect(normalized).not_to include('credential')
        expect(normalized).not_to include('secret')
        expect(normalized).not_to include('apikey')
      end
    end
  end

  # Identity is the config name, so two config names sharing one endpoint stay
  # distinct instances — the physical id is dedup/diagnostics, never identity.
  describe 'config-name identity' do
    it 'claims both config names as distinct, available instances' do
      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
        .and_return({ alpha: alpha_cfg, beta: alpha_cfg })
      runner.refresh

      claimed = registry.snapshot.each_instance.map { |record| record.instance_key.instance_id }.sort
      expect(claimed).to eq(%w[alpha beta])
      expect(registry.snapshot.instance(instance_key: key_for(alpha_cfg, name: :alpha)).availability.state)
        .to eq(:available)
      expect(registry.snapshot.instance(instance_key: key_for(alpha_cfg, name: :beta)).availability.state)
        .to eq(:available)
    end

    it 'derives the same physical_id for both but keeps distinct instance keys' do
      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
        .and_return({ alpha: alpha_cfg, beta: alpha_cfg })
      runner.refresh

      alpha = registry.snapshot.instance(instance_key: key_for(alpha_cfg, name: :alpha))
      beta = registry.snapshot.instance(instance_key: key_for(alpha_cfg, name: :beta))
      expect(alpha.instance_key.physical_id).to eq(beta.instance_key.physical_id)
      expect(alpha.instance_key).not_to eq(beta.instance_key)
    end
  end

  # First-tick boundary smoke on this provider's runner: the OpenAI catalog +
  # readiness stubs feed the shared claim/activate path, and the D14 display
  # write-back lands in the OpenAI settings subtree.
  describe 'first-tick activation and display write-back' do
    it 'activates the configured instance and publishes the catalog models as lanes' do
      runner.refresh

      key = key_for(alpha_cfg)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(registry.snapshot.lanes_for(instance_key: key).map(&:model))
        .to contain_exactly('gpt-4o', 'text-embedding-3-small')
    end

    it 'writes the 5-key display health and the published capability union into settings' do
      runner.refresh

      health = settings_tree.dig(:instances, :alpha, :health)
      expect(health).to include(state: :available, last_probe_outcome: :success, source: :startup_readiness)
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(String)
      expect(settings_tree.dig(:instances, :alpha, :capabilities))
        .to contain_exactly(:completion, :embedding, :streaming, :structured_output, :tools, :vision)
    end
  end

  describe 'offering equivalence' do
    it 'treats a same-size change in duplicate multiplicity as significant' do
      chat = draft_for('gpt-4o')
      embedding = draft_for('text-embedding-3-small')

      # The pipeline keeps the complement name (offerings_equivalent?): a
      # same-size duplicate-multiplicity change is NOT equivalent.
      expect(runner.send(:offerings_equivalent?, [chat, chat, embedding], [chat, embedding, embedding]))
        .to be(false)
    end
  end

  # Readiness-race ownership: the readiness I/O window is where removal and
  # activation race. Proven at the provider boundary — the real pipeline and
  # registry state machine, only the probe boundary stubbed.
  describe 'readiness races' do
    it 'rebuilds from current settings after draft construction and before initial activation' do
      live_settings = full_weight_settings(provider: 100, instance: 115, model: 120, tier: 150)
      stub_live_settings(live_settings)
      entered_readiness = Queue.new
      resume_readiness = Queue.new
      allow(runner).to receive(:check_health) do |**_kwargs|
        entered_readiness << true
        resume_readiness.pop
        readiness_result(ready: true)
      end

      worker = Thread.new { runner.refresh }
      entered_readiness.pop
      live_settings[:extensions][:llm][:openai][:weight] = 125
      resume_readiness << true
      worker.join

      state = runner.states['alpha']
      expect(state[:published]).to be(true)
      expect(state[:offerings].find { |item| item.model == 'gpt-4o' }.weight_inputs[:provider]).to eq(125)
      record = registry.snapshot.lanes_for(instance_key: key_for(alpha_cfg)).find { |item| item.model == 'gpt-4o' }
      expect(record.weight_inputs[:provider]).to eq(125)
    end

    it 'lets removal win a paused readiness race without late activation or display writes' do
      entered_readiness = Queue.new
      resume_readiness = Queue.new
      allow(runner).to receive(:check_health) do |**_kwargs|
        entered_readiness << true
        resume_readiness.pop
        readiness_result(ready: true)
      end
      allow(runner).to receive(:write_instance_health).and_call_original
      publisher = runner.publisher
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original

      worker = Thread.new { runner.refresh }
      entered_readiness.pop
      runner.remove_instance_state('alpha')
      resume_readiness << true
      worker.join

      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(runner).not_to have_received(:write_instance_health)
      expect(runner.states.key?('alpha')).to be(false)
    end
  end

  describe 'shutdown' do
    it 'removes all instances and clears display health' do
      runner.refresh
      expect(registry.snapshot.each_instance.to_a).not_to be_empty

      runner.remove_all_instances

      expect(registry.snapshot.each_instance.to_a).to be_empty
      expect(settings_tree.dig(:instances, :alpha, :health)).to be_nil
      expect(settings_tree.dig(:instances, :alpha, :capabilities)).to be_nil
    end
  end

  # Actor periodicity (D9): the timer and dispatch convention are inherited
  # from the shared base (lex-llm); proven here only as a provider-side smoke
  # — the OpenAI actor honors the interval on the OpenAI settings tree.
  describe 'actor periodicity (D9)' do
    let(:actor) { Legion::Extensions::Llm::Openai::Actor::Discovery.new }

    it 'honors an operator-configured interval' do
      settings_tree[:discovery] = { interval_seconds: 120 }
      expect(actor.time).to eq(120)
    end

    it 'falls back to the registered default when the interval is missing' do
      settings_tree.delete(:discovery)
      default = Legion::Extensions::Llm::Openai.default_settings.dig(:discovery, :interval_seconds)
      expect(actor.time).to eq(default)
    end

    it 'never returns nil for a malformed interval' do
      settings_tree[:discovery] = { interval_seconds: nil }
      expect(actor.time).to eq(300)
    end
  end
end
