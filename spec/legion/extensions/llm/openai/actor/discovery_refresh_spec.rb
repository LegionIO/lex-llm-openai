# frozen_string_literal: true

require 'digest'
require 'spec_helper'
require 'faraday'

RSpec.describe Legion::Extensions::Llm::Openai::Actor::DiscoveryRefresh do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
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

    it 'skips configured instances without an API credential' do
      stub_models
      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
        .and_return({ synthetic_default: { openai_api_base: 'https://api.openai.com' } })
      actor.manual

      key = key_for({ openai_api_base: 'https://api.openai.com' })
      expect(registry.snapshot.publication_status(instance_key: key)).to be_nil
      expect(registry.snapshot.each_instance.to_a).to be_empty
    end

    it 'warns exactly once per actor lifetime when a credential-less instance is skipped' do
      warnings = []
      fake_log = Object.new
      fake_log.define_singleton_method(:warn) { |message = nil, **| warnings << message.to_s }
      allow(actor).to receive(:log).and_return(fake_log)
      allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
        .and_return({ default: { openai_api_base: 'https://api.openai.com' } })

      actor.manual
      actor.manual

      expect(registry.snapshot.each_instance.to_a).to be_empty
      expect(warnings.size).to eq(1), 'the credential-less skip must be loud but not per-tick spam'
      expect(warnings.first).to include('default')
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
