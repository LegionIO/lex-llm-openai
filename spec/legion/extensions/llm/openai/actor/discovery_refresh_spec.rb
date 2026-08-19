# frozen_string_literal: true

require 'digest'
require 'spec_helper'
require 'faraday'

RSpec.describe Legion::Extensions::Llm::Openai::Actor::DiscoveryRefresh do
  let(:actor) { described_class.new }

  let(:alpha_cfg) do
    {
      openai_api_base: 'https://api.openai.com',
      openai_api_key: 'sk-lifecycle-alpha',
      openai_organization_id: 'org-alpha',
      tier: :frontier
    }
  end

  let(:beta_cfg) do
    {
      openai_api_base: 'https://beta-proxy.internal:8443',
      openai_api_key: 'sk-lifecycle-beta',
      tier: :frontier
    }
  end

  let(:catalog) { '{"data": [{"id": "gpt-4o"}, {"id": "text-embedding-3-small"}]}' }

  before do
    registry.reset!
    # The Lex helper resolves settings to the shared extension section
    # (Legion::Settings[:extensions][:llm][:openai]); clear it per example.
    actor.settings.clear
    allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances).and_return({ alpha: alpha_cfg })
  end

  after { registry.reset! }

  def registry = Legion::Extensions::Llm::Inventory::Registry

  def stub_models(body = catalog)
    allow(actor).to receive(:build_api_connection).and_return(
      instance_double(Faraday::Connection, get: Faraday::Response.new(status: 200, body: body))
    )
  end

  def stub_models_unreachable
    connection = instance_double(Faraday::Connection)
    allow(connection).to receive(:get) { raise Faraday::ConnectionFailed, 'connection refused' }
    allow(actor).to receive(:build_api_connection).and_return(connection)
  end

  # The registry key for a discovered instance: the operator's CONFIG NAME as
  # identity, the derived endpoint/credential id as the secondary physical_id.
  def key_for(cfg, name: :alpha)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :openai,
      instance_id: name.to_s,
      physical_id: actor.send(:derive_physical_id, instance_cfg: cfg)
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

  def stub_live_settings(live_settings)
    allow(Legion::Settings).to receive(:dig) { |*path| live_settings.dig(*path) }
  end

  def alpha_state
    actor.instance_variable_get(:@instance_states).fetch('alpha')
  end

  def readiness(ready:)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: ready, reason: ready ? 'ready' : 'not ready', metadata: {}
    )
  end

  def draft_for(model_id)
    actor.send(
      :build_offering_draft,
      model_id: model_id,
      model_data: { id: model_id },
      instance_cfg: alpha_cfg,
      instance_key: key_for(alpha_cfg)
    )
  end

  describe 'initial claim and activation' do
    it 'claims, probes, and activates configured instances on the first tick' do
      stub_models
      actor.manual

      key = key_for(alpha_cfg)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(registry.snapshot.offerings_for(instance_key: key).map(&:model))
        .to contain_exactly('gpt-4o', 'text-embedding-3-small')
    end

    it 'writes display health and capabilities into settings after activation' do
      stub_models
      actor.manual

      health = actor.settings.dig(:instances, :alpha, :health)
      expect(health).to include(
        circuit_state: :closed, denied: false, available: true, adjustment: 0,
        last_probe_outcome: :success, source: :startup_readiness
      )
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(String)
      expect(actor.settings.dig(:instances, :alpha, :capabilities))
        .to contain_exactly(:completion, :embedding, :streaming)
    end

    it 'stays initializing after a failed initial readiness probe' do
      stub_models_unreachable
      actor.manual

      key = key_for(alpha_cfg)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
      expect(actor.settings.dig(:instances, :alpha, :health)).to include(
        available: false, last_probe_outcome: :failure, source: :startup_readiness
      )
    end
  end

  describe 'config-name identity' do
    it 'publishes the config name as instance_id and the derived endpoint as physical_id' do
      stub_models
      actor.manual

      record = registry.snapshot.each_instance.to_a.first
      expect(record.instance_key.instance_id).to eq('alpha')
      fingerprint = Digest::SHA256.hexdigest('sk-lifecycle-alpha')[0, 8]
      expect(record.instance_key.physical_id).to eq("api.openai.com:443/ak:#{fingerprint}/org:org-alpha")
    end

    it 'keeps two config names pointing at the same endpoint as distinct instances' do
      stub_models
      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
        .and_return({ alpha: alpha_cfg, beta: alpha_cfg })
      actor.manual

      alpha_record = registry.snapshot.instance(instance_key: key_for(alpha_cfg, name: :alpha))
      beta_record = registry.snapshot.instance(instance_key: key_for(alpha_cfg, name: :beta))
      expect(alpha_record.availability.state).to eq(:available)
      expect(beta_record.availability.state).to eq(:available)
      expect(registry.snapshot.each_instance.to_a.size).to eq(2)
    end
  end

  describe 'recovery of a stuck-initializing instance (D4)' do
    it 're-activates on a later passing readiness probe and heals the catalog' do
      stub_models_unreachable
      actor.manual
      key = key_for(alpha_cfg)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      stub_models
      actor.manual
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)

      # Catalog discovery failed at claim time; the next activated-tick
      # replace publishes the real catalog.
      actor.manual
      expect(registry.snapshot.offerings_for(instance_key: key).map(&:model))
        .to contain_exactly('gpt-4o', 'text-embedding-3-small')
      expect(actor.settings.dig(:instances, :alpha, :health)).to include(available: true)
    end
  end

  describe 'tick reconciliation' do
    it 'claims instances configured after boot on the next tick' do
      stub_models
      actor.manual

      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
        .and_return({ alpha: alpha_cfg, beta: beta_cfg })
      actor.manual

      beta_record = registry.snapshot.instance(instance_key: key_for(beta_cfg, name: :beta))
      expect(beta_record.availability.state).to eq(:available)
    end

    it 'removes instances that disappear from configuration' do
      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
        .and_return({ alpha: alpha_cfg, beta: beta_cfg })
      stub_models
      actor.manual

      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances).and_return({ alpha: alpha_cfg })
      actor.manual

      expect(registry.snapshot.instance(instance_key: key_for(beta_cfg, name: :beta))).to be_nil
      expect(actor.settings.dig(:instances, :beta, :health)).to be_nil
      expect(actor.settings.dig(:instances, :beta, :capabilities)).to be_nil
    end

    it 'claims configured instances without an API credential' do
      stub_models
      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
        .and_return({ synthetic_default: { openai_api_base: 'https://api.openai.com' } })
      actor.manual

      key = key_for({ openai_api_base: 'https://api.openai.com' }, name: :synthetic_default)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end
  end

  describe 'offerings refresh (D3 churn)' do
    it 'replaces the snapshot only when the catalog changed' do
      stub_models
      actor.manual
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original

      stub_models
      actor.manual
      expect(publisher).not_to have_received(:replace_instance_snapshot)

      stub_models('{"data": [{"id": "gpt-4o"}]}')
      actor.manual
      expect(publisher).to have_received(:replace_instance_snapshot).once
      expect(registry.snapshot.offerings_for(instance_key: key_for(alpha_cfg)).map(&:model)).to eq(['gpt-4o'])
    end
  end

  describe 'write-time weight publication on the ordinary actor cadence' do
    let(:live_settings) { full_weight_settings(provider: 110, instance: 115, model: 120, tier: 150) }

    before do
      stub_live_settings(live_settings)
      stub_models
    end

    it 'stores the exact four-axis pair and product on drafts built by the production writer' do
      draft = draft_for('gpt-4o')

      expect(draft.weight_inputs).to eq(
        tier: 150, provider: 110, instance: 115, model_or_offering: 120
      )
      expect(draft.base_weight).to eq(227_700_000)
    end

    it 'publishes one replacement for a weight-only change on the next ordinary pass' do
      live_settings[:extensions][:llm][:openai][:weight] = 100
      actor.manual
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      live_settings[:extensions][:llm][:openai][:weight] = 110

      actor.manual

      status = registry.snapshot.publication_status(instance_key: key_for(alpha_cfg))
      offering = registry.snapshot.offerings_for(instance_key: key_for(alpha_cfg)).find do |item|
        item.model == 'gpt-4o'
      end
      expect(publisher).to have_received(:replace_instance_snapshot).once
      expect(status.published_sequence).to eq(2)
      expect(offering.weight_inputs[:provider]).to eq(110)
      expect(offering.base_weight).to eq(227_700_000)
    end

    it 'publishes nothing when settings change without changing the weight pair' do
      actor.manual
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      live_settings[:extensions][:llm][:openai][:unrelated] = 'changed'

      actor.manual

      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(alpha_state[:sequence]).to eq(1)
    end

    it 'preserves zero as a disable component and raises on false' do
      live_settings[:extensions][:llm][:openai][:weight] = 0
      expect(draft_for('gpt-4o').weight_inputs[:provider]).to eq(0)

      live_settings[:extensions][:llm][:openai][:weight] = false
      expect { draft_for('gpt-4o') }.to raise_error(ArgumentError, /Integer >= 0/)

      actor.manual
      expect(registry.snapshot.publication_status(instance_key: key_for(alpha_cfg))).to be_nil
      expect(actor.instance_variable_get(:@instance_states)).not_to have_key('alpha')
    end

    it 'logs each dormant weight once, clears on appearance, and logs on re-disappearance' do
      messages = []
      logger = instance_double(Logger).as_null_object
      allow(logger).to receive(:info) do |message = nil, &block|
        messages << (message || block.call)
      end
      allow(actor).to receive(:log).and_return(logger)
      provider = live_settings[:extensions][:llm][:openai]
      provider[:instances][:ghost] = { weight: 125 }

      actor.manual
      actor.manual
      provider[:instances].delete(:ghost)
      actor.manual
      provider[:instances][:ghost] = { weight: 125 }
      actor.manual

      expected = '[llm][openai] action=dormant_weight weight_key=[:openai, :instance, "ghost"] ' \
                 'no_lane_published=true'
      expect(messages.count(expected)).to eq(2)
    end

    it 'does not replace or advance sequence across ten unchanged ordinary passes' do
      actor.manual
      10.times { actor.manual }

      expect(alpha_state[:sequence]).to eq(1)
    end

    it 'does not couple actor cadence or shutdown to the Legion::Settings lifecycle' do
      %i[on_reload reload! reset! off_reload].each do |method_name|
        allow(Legion::Settings).to receive(method_name)
      end

      actor.manual
      actor.shutdown

      %i[on_reload reload! reset! off_reload].each do |method_name|
        expect(Legion::Settings).not_to have_received(method_name)
      end
    end

    it 'serializes interleaved ordinary commits with monotonic publications and matching final cache' do
      actor.manual
      published = []
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_wrap_original do |original, **kwargs|
        published << kwargs
        original.call(**kwargs)
      end
      threads = %w[gpt-4.1 gpt-5.2].map do |model_id|
        Thread.new do
          actor.send(
            :commit_discovered_offerings,
            instance_id: 'alpha', state: alpha_state, offerings: [draft_for(model_id)]
          )
        end
      end
      threads.each(&:join)

      expect(published.map { |entry| entry[:sequence] }).to eq([2, 3])
      expect(published.map { |entry| entry[:offerings].first.model }.uniq.length).to eq(2)
      expect(alpha_state[:offerings]).to eq(published.last[:offerings])
      expect(alpha_state[:sequence]).to eq(3)
    end

    it 'leaves cache and sequence unchanged on replacement failure and retries on the next pass' do
      actor.manual
      state = alpha_state
      original_offerings = state[:offerings]
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_raise(StandardError, 'publish failed')

      expect do
        actor.send(
          :commit_discovered_offerings,
          instance_id: 'alpha', state: state, offerings: [draft_for('gpt-5.2')]
        )
      end.to raise_error(StandardError, 'publish failed')
      expect(state[:sequence]).to eq(1)
      expect(state[:offerings]).to equal(original_offerings)

      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      actor.send(
        :commit_discovered_offerings,
        instance_id: 'alpha', state: state, offerings: [draft_for('gpt-5.2')]
      )
      expect(state[:sequence]).to eq(2)
      expect(state[:offerings].first.model).to eq('gpt-5.2')
    end

    it 'rebuilds from current settings after draft construction and before initial activation' do
      live_settings[:extensions][:llm][:openai][:weight] = 100
      entered_readiness = Queue.new
      resume_readiness = Queue.new
      allow(actor).to receive(:check_readiness) do
        entered_readiness << true
        resume_readiness.pop
        readiness(ready: true)
      end

      worker = Thread.new { actor.manual }
      entered_readiness.pop
      live_settings[:extensions][:llm][:openai][:weight] = 125
      resume_readiness << true
      worker.join

      state = alpha_state
      expect(state[:published]).to be(true)
      expect(state[:offerings].find { |item| item.model == 'gpt-4o' }.weight_inputs[:provider]).to eq(125)
      record = registry.snapshot.offerings_for(instance_key: key_for(alpha_cfg)).find { |item| item.model == 'gpt-4o' }
      expect(record.weight_inputs[:provider]).to eq(125)
    end

    it 'updates an unpublished cache without replacing or counting it as a dormant match' do
      messages = []
      logger = instance_double(Logger).as_null_object
      allow(logger).to receive(:info) do |message = nil, &block|
        messages << (message || block.call)
      end
      allow(actor).to receive_messages(log: logger, check_readiness: readiness(ready: false),
                                       fetch_models: [{ id: 'gpt-4o' }])
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      live_settings[:extensions][:llm][:openai][:weight] = 100
      actor.manual
      live_settings[:extensions][:llm][:openai][:weight] = 130

      actor.manual

      state = alpha_state
      expect(state[:published]).to be(false)
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(130)
      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(messages).to include(
        '[llm][openai] action=dormant_weight weight_key=[:openai, :provider] no_lane_published=true'
      )
    end

    it 'lets removal win a paused readiness race without late activation or display writes' do
      entered_readiness = Queue.new
      resume_readiness = Queue.new
      allow(actor).to receive(:check_readiness) do
        entered_readiness << true
        resume_readiness.pop
        readiness(ready: true)
      end
      allow(actor).to receive(:write_instance_health).and_call_original
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original

      worker = Thread.new { actor.manual }
      entered_readiness.pop
      actor.send(:remove_instance_state, 'alpha')
      resume_readiness << true
      worker.join

      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(actor).not_to have_received(:write_instance_health)
      expect(actor.instance_variable_get(:@instance_states)).not_to have_key('alpha')
    end

    it 'keeps activation state unpublished on publisher failure and permits a later retry' do
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:activate_instance_snapshot).and_raise(StandardError, 'activation failed')

      actor.manual

      state = alpha_state
      expect(state[:published]).to be(false)
      expect(state[:sequence]).to eq(0)
      original_offerings = state[:offerings]

      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      actor.manual
      expect(state[:published]).to be(true)
      expect(state[:sequence]).to eq(1)
      expect(state[:offerings]).not_to equal(original_offerings)
    end
  end

  describe 'shutdown' do
    it 'removes all instances and clears display health' do
      stub_models
      actor.manual
      expect(registry.snapshot.each_instance.to_a).not_to be_empty

      actor.shutdown

      expect(registry.snapshot.each_instance.to_a).to be_empty
      expect(actor.settings.dig(:instances, :alpha, :health)).to be_nil
      expect(actor.settings.dig(:instances, :alpha, :capabilities)).to be_nil
    end
  end

  describe 'discovery interval (D9)' do
    it 'reads the registered discovery interval from settings' do
      actor.settings[:discovery] = { interval_seconds: 120 }
      expect(actor.time).to eq(120)
    end

    it 'falls back to the registered default when settings are empty' do
      expect(actor.time).to eq(
        Legion::Extensions::Llm::Openai.default_settings.dig(:discovery, :interval_seconds)
      )
    end

    it 'never returns nil for a malformed interval' do
      actor.settings[:discovery] = { interval_seconds: nil }
      expect(actor.time).not_to be_nil
    end
  end
end
