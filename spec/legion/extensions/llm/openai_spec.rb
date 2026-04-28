# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Openai do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:chat_model) { Legion::Extensions::Llm::Model::Info.new(id: 'gpt-5.2', provider: :openai) }
  let(:registry_publisher) { instance_double(described_class::RegistryPublisher) }

  before do
    Legion::Extensions::Llm.config.openai_api_key = 'test-key'
    Legion::Extensions::Llm.config.openai_api_base = nil
    Legion::Extensions::Llm.config.openai_organization_id = nil
    Legion::Extensions::Llm.config.openai_project_id = nil
    Legion::Extensions::Llm.config.openai_use_system_role = nil
  end

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:openai)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('https://api.openai.com')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end

  it 'registers the Legion::Extensions::Llm provider class' do
    expect(Legion::Extensions::Llm::Provider.resolve(:openai)).to eq(described_class::Provider)
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

  it 'maps discovered models to explicit routing metadata' do
    expect(parsed_models.map(&:capabilities)).to eq([%w[streaming function_calling vision], %w[embeddings]])
    expect(parsed_models.map { |model| model.modalities.to_h }).to eq(expected_modalities)
  end

  it 'publishes discovered models asynchronously through the registry publisher' do
    stub_registry_publisher
    stub_model_discovery

    models = provider.list_models

    expect_registry_publish(models)
  end

  it 'builds sanitized lex-llm registry events for OpenAI model availability' do
    events = capture_registry_events([chat_model], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:openai)
    expect(events.first.to_h.dig(:offering, :model)).to eq('gpt-5.2')
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

  def parsed_models
    provider.send(:parse_list_models_response, fake_response(models_body), :openai,
                  described_class::Provider.capabilities)
  end

  def expected_modalities
    [
      { input: %w[text image], output: %w[text] },
      { input: %w[text], output: %w[embeddings] }
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

  def capture_registry_events(models, readiness:)
    publisher = described_class::RegistryPublisher.new
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end
end
