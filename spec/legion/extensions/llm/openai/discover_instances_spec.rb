# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Openai, '.discover_instances' do
  subject(:discover) { described_class.discover_instances }

  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }

  before do
    allow(credential_sources).to receive_messages(
      env: nil,
      codex_token: nil,
      codex_openai_key: nil,
      claude_config_value: nil,
      setting: nil
    )
  end

  context 'with OPENAI_API_KEY env var' do
    before { stub_env('OPENAI_API_KEY', 'sk-env-key') }

    it 'returns an :env instance with tier :frontier' do
      expect(discover).to include(env: a_hash_including(openai_api_key: 'sk-env-key', tier: :frontier))
    end
  end

  context 'with CODEX_API_KEY env var' do
    before { stub_env('CODEX_API_KEY', 'sk-codex-env-key') }

    it 'returns a :codex_env instance with tier :frontier' do
      expect(discover).to include(codex_env: a_hash_including(openai_api_key: 'sk-codex-env-key', tier: :frontier))
    end
  end

  context 'with codex bearer token' do
    before { allow(credential_sources).to receive(:codex_token).and_return('codex-bearer-tok') }

    it 'returns a :codex instance with tier :frontier' do
      expect(discover).to include(codex: a_hash_including(openai_api_key: 'codex-bearer-tok', tier: :frontier))
    end
  end

  context 'with codex openai key' do
    before { allow(credential_sources).to receive(:codex_openai_key).and_return('codex-oai-key') }

    it 'returns a :codex_key instance with tier :frontier' do
      expect(discover).to include(codex_key: a_hash_including(openai_api_key: 'codex-oai-key', tier: :frontier))
    end
  end

  context 'with claude config openaiApiKey' do
    before { stub_claude_config('claude-oai-key') }

    it 'returns a :claude instance with tier :frontier' do
      expect(discover).to include(claude: a_hash_including(openai_api_key: 'claude-oai-key', tier: :frontier))
    end
  end

  context 'with extension settings' do
    before { stub_settings(api_key: 'settings-key', organization_id: 'org-123') }

    it 'returns a :settings instance with merged config and tier :frontier' do
      result = discover[:settings]
      expect(result[:openai_api_key]).to eq('settings-key')
      expect(result[:openai_organization_id]).to eq('org-123')
      expect(result[:tier]).to eq(:frontier)
      expect(result).not_to have_key(:api_key)
      expect(result).not_to have_key(:organization_id)
    end
  end

  context 'with extension settings missing api_key' do
    before { stub_settings(organization_id: 'org-only') }

    it 'does not add a :settings instance' do
      expect(discover).not_to have_key(:settings)
    end
  end

  context 'with named settings instances' do
    before { stub_settings(instances: { litellm: { openai_api_key: 'gw-key', openai_api_base: 'http://litellm:4000' } }) }

    it 'returns each instance with tier :frontier' do
      result = discover[:litellm]
      expect(result[:openai_api_key]).to eq('gw-key')
      expect(result[:openai_api_base]).to eq('http://litellm:4000')
      expect(result[:tier]).to eq(:frontier)
    end
  end

  context 'with multiple named settings instances' do
    before do
      stub_settings(
        instances: {
          gw_a: { openai_api_key: 'key-a', openai_api_base: 'http://a:4000' },
          gw_b: { openai_api_key: 'key-b', openai_api_base: 'http://b:4000' }
        }
      )
    end

    it 'returns all named instances' do
      expect(discover.keys).to include(:gw_a, :gw_b)
      expect(discover[:gw_a][:tier]).to eq(:frontier)
      expect(discover[:gw_b][:tier]).to eq(:frontier)
    end
  end

  context 'with named settings instances containing non-hash entries' do
    before { stub_settings(instances: { valid: { openai_api_key: 'key' }, invalid: 'not-a-hash' }) }

    it 'skips non-hash instance entries' do
      expect(discover).to have_key(:valid)
      expect(discover).not_to have_key(:invalid)
    end
  end

  context 'with multiple sources providing the same key' do
    before do
      stub_env('OPENAI_API_KEY', 'same-key')
      stub_claude_config('same-key')
    end

    it 'deduplicates via CredentialSources.dedup_credentials' do
      allow(credential_sources).to receive(:dedup_credentials).and_call_original
      discover
      expect(credential_sources).to have_received(:dedup_credentials)
    end
  end

  context 'with all sources available' do
    before do
      stub_env('OPENAI_API_KEY', 'env-key')
      stub_env('CODEX_API_KEY', 'codex-env-key')
      allow(credential_sources).to receive_messages(codex_token: 'codex-tok', codex_openai_key: 'codex-oai-key')
      stub_claude_config('claude-key')
      stub_settings(api_key: 'settings-key', instances: { my_gw: { openai_api_key: 'gw-key' } })
    end

    it 'returns all discovered instances' do
      expect(discover.keys).to include(:env, :codex_env, :codex, :codex_key, :claude, :settings, :my_gw)
    end
  end

  context 'with no sources available' do
    it 'returns an empty hash' do
      expect(discover).to eq({})
    end
  end

  # NOTE: .resolve_default_model removed in SSOT v3 migration (v0.5.0).
  # Model selection is now handled by the routing layer via discovered offerings.

  # -- helpers ----------------------------------------------------------------

  def stub_env(key, value)
    allow(credential_sources).to receive(:env).with(key).and_return(value)
  end

  def stub_claude_config(value)
    allow(credential_sources).to receive(:claude_config_value).with(:openaiApiKey).and_return(value)
  end

  def stub_settings(config)
    allow(credential_sources).to receive(:setting)
      .with(:extensions, :llm, :openai)
      .and_return(config)
  end
end
