# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Openai do
  let(:provider) { described_class::Provider.new(LexLLM.config) }
  let(:chat_model) { LexLLM::Model::Info.new(id: 'gpt-5.2', provider: :openai) }

  before do
    LexLLM.config.openai_api_key = 'test-key'
    LexLLM.config.openai_api_base = nil
    LexLLM.config.openai_organization_id = nil
    LexLLM.config.openai_project_id = nil
    LexLLM.config.openai_use_system_role = nil
  end

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:openai)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('https://api.openai.com')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end

  it 'registers the LexLLM provider class' do
    expect(LexLLM::Provider.resolve(:openai)).to eq(described_class::Provider)
  end

  it 'uses the shared OpenAI-compatible LexLLM adapter' do
    expect(described_class::Provider.ancestors).to include(LexLLM::Provider::OpenAICompatible)
  end

  it 'exposes OpenAI endpoint helpers' do
    expect(provider.api_base).to eq('https://api.openai.com')
    expect(provider.headers).to include('Authorization' => 'Bearer test-key')
    expect(endpoint_helpers).to eq(expected_endpoint_helpers)
  end

  it 'maps chat completion payloads through the shared LexLLM provider adapter' do
    expect(chat_payload).to include(expected_chat_payload)
  end

  it 'advertises OpenAI model family capabilities' do
    expect(openai_capability_checks).to eq([true, true, true, true, true, false])
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
    provider.send(:render_payload, [LexLLM::Message.new(role: :user, content: 'brief')],
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
end
