# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Openai do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:chat_model) { Legion::Extensions::Llm::Model::Info.new(id: 'gpt-5.2', provider: :openai) }
  let(:registry_publisher) { instance_double(Legion::Extensions::Llm::RegistryPublisher) }

  before do
    Legion::Extensions::Llm.config.openai_api_key = 'test-key'
    Legion::Extensions::Llm.config.openai_api_base = nil
    Legion::Extensions::Llm.config.openai_organization_id = nil
    Legion::Extensions::Llm.config.openai_project_id = nil
    Legion::Extensions::Llm.config.openai_use_system_role = nil
  end

  it 'exposes provider defaults through the shared provider settings shape' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings[:enabled]).to be true
    expect(settings[:provider_family]).to eq(:openai)
    expect(instance[:default_model]).to eq('gpt-4o')
    expect(instance.dig(:credentials, :api_key)).to eq('env://OPENAI_API_KEY')
    expect(instance.dig(:fleet, :capabilities)).to eq(%i[chat stream_chat embed image])
  end

  it 'advertises all supported OpenAI usage families' do
    instance = described_class.default_settings.dig(:instances, :default)

    expect(instance[:usage]).to eq(
      inference: true,
      embedding: true,
      moderation: true,
      image: true,
      audio: true
    )
  end

  it 'does not register the provider in the deprecated Provider.providers hash' do
    # The old Provider.register call has been removed; loading the gem should
    # not add an entry to the deprecated providers hash.
    unless Legion::Extensions::Llm::Provider.respond_to?(:providers)
      next skip('Provider.providers removed from lex-llm')
    end

    expect(Legion::Extensions::Llm::Provider.providers).not_to have_key(:openai)
  end

  it 'uses the shared OpenAI-compatible Legion::Extensions::Llm adapter' do
    expect(described_class::Provider.ancestors).to include(Legion::Extensions::Llm::Provider::OpenAICompatible)
  end

  it 'exposes OpenAI endpoint helpers' do
    expect(provider.api_base).to eq('https://api.openai.com')
    expect(provider.headers).to include('Authorization' => 'Bearer test-key')
    expect(endpoint_helpers).to eq(expected_endpoint_helpers)
  end

  it 'maps chat completion payloads through the shared Legion::Extensions::Llm provider adapter' do
    expect(chat_payload).to include(expected_chat_payload)
  end

  it 'advertises OpenAI model family capabilities' do
    expect(openai_capability_checks).to eq([true, true, true, true, true, false])
  end

  it 'maps discovered models to Model::Info with static capability map' do
    models = provider.send(:build_model_infos, models_body)

    gpt_model = models.find { |m| m.id == 'gpt-5.2' }
    embed_model = models.find { |m| m.id == 'text-embedding-3-small' }

    expect(gpt_model).to be_a(Legion::Extensions::Llm::Model::Info)
    expect(gpt_model.capabilities).to include(:completion, :streaming, :function_calling, :vision)
    expect(gpt_model.modalities_input).to include(:text, :image)

    expect(embed_model.capabilities).to eq([:embedding])
    expect(embed_model.modalities_output).to eq([:embeddings])
  end

  it 'publishes discovered models asynchronously through the base registry publisher' do
    stub_registry_publisher
    stub_model_discovery

    models = provider.list_models

    expect_registry_publish(models)
  end

  it 'uses the base RegistryPublisher from lex-llm' do
    publisher = described_class::Provider.registry_publisher
    expect(publisher).to be_a(Legion::Extensions::Llm::RegistryPublisher)
    expect(publisher.provider_family).to eq(:openai)
  end

  it 'builds sanitized lex-llm registry events via the base RegistryEventBuilder' do
    builder = Legion::Extensions::Llm::RegistryEventBuilder.new(provider_family: :openai)
    event = builder.model_available(chat_model, readiness: { ready: true })

    expect(event.to_h).to include(event_type: :offering_available)
    expect(event.to_h.dig(:offering, :provider_family)).to eq(:openai)
    expect(event.to_h.dig(:offering, :model)).to eq('gpt-5.2')
  end

  it 'does not define local RegistryPublisher or RegistryEventBuilder classes' do
    expect(described_class.const_defined?(:RegistryPublisher, false)).to be false
    expect(described_class.const_defined?(:RegistryEventBuilder, false)).to be false
  end

  it 'does not ship a local transport directory' do
    expect(described_class.const_defined?(:Transport, false)).to be false
  end

  describe '.discover_instances' do
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive_messages(
        env: nil,
        codex_token: nil,
        codex_openai_key: nil,
        claude_config_value: nil,
        setting: nil
      )
    end

    it 'normalizes generic extension settings to provider config keys' do # rubocop:disable RSpec/ExampleLength
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :openai)
        .and_return({ api_key: 'sk-settings', base_url: 'https://openai.example/v1',
                      organization_id: 'org-123', project_id: 'proj-123' })

      instance = described_class.discover_instances[:settings]

      expect(instance).to include(openai_api_key: 'sk-settings',
                                  openai_api_base: 'https://openai.example/v1',
                                  openai_organization_id: 'org-123',
                                  openai_project_id: 'proj-123',
                                  tier: :frontier)
      expect(instance).not_to have_key(:base_url)
    end

    it 'normalizes named instances to OpenAI provider config keys' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :openai)
        .and_return({ instances: { local: { api_key: 'sk-local', endpoint: 'http://localhost:8000/v1' } } })

      expect(described_class.discover_instances[:local]).to include(
        openai_api_key: 'sk-local',
        openai_api_base: 'http://localhost:8000/v1',
        tier: :frontier
      )
    end
  end

  def endpoint_helpers
    [
      provider.chat_url,
      provider.stream_url,
      *model_endpoint_helpers,
      *image_endpoint_helpers,
      provider.transcription_url
    ]
  end

  def model_endpoint_helpers
    [provider.models_url, provider.embedding_url(model: 'text-embedding-3-small'), provider.moderation_url]
  end

  def image_endpoint_helpers
    [provider.images_url, provider.images_url(with: 'image.png'), provider.image_variation_url]
  end

  def expected_endpoint_helpers
    [
      '/v1/chat/completions',
      '/v1/chat/completions',
      '/v1/models',
      '/v1/embeddings',
      '/v1/moderations',
      '/v1/images/generations',
      '/v1/images/edits',
      '/v1/images/variations',
      '/v1/audio/transcriptions'
    ]
  end

  def chat_payload
    provider.send(:render_payload, [Legion::Extensions::Llm::Message.new(role: :user, content: 'brief')],
                  tools: {}, temperature: 0.2, model: chat_model, stream: true, schema: nil,
                  thinking: { effort: 'medium' }, tool_prefs: nil)
  end

  def expected_chat_payload
    {
      model: 'gpt-5.2',
      messages: [{ role: 'user', content: 'brief' }],
      stream: true,
      temperature: 0.2,
      reasoning_effort: 'medium'
    }
  end

  def openai_capability_checks
    capabilities = described_class::Provider::Capabilities
    [
      capabilities.chat?('gpt-5.2'),
      capabilities.embeddings?('text-embedding-3-small'),
      capabilities.moderation?('omni-moderation-latest'),
      capabilities.images?('gpt-image-1'),
      capabilities.audio_transcription?('gpt-4o-transcribe'),
      capabilities.chat?('text-embedding-3-small')
    ]
  end

  def models_body
    {
      'data' => [
        { 'id' => 'gpt-5.2', 'created' => 1 },
        { 'id' => 'text-embedding-3-small', 'created' => 2 }
      ]
    }
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end

  def stub_registry_publisher
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)
  end

  def stub_model_discovery
    allow(provider.connection).to receive(:get).with('/v1/models').and_return(fake_response(models_body))
  end

  def expect_registry_publish(models)
    expect(registry_publisher).to have_received(:publish_models_async)
      .with(models, readiness: hash_including(provider: :openai, live: false))
  end
end
