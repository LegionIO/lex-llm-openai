# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/openai/provider'

RSpec.describe Legion::Extensions::Llm::Openai::Provider do # CapabilityPolicy integration
  let(:provider) { described_class.new(Legion::Extensions::Llm.config) }
  let(:credential_sources) { Legion::Extensions::Llm::CredentialSources }

  before do
    Legion::Extensions::Llm.config.openai_api_key = 'test-key'
    Legion::Extensions::Llm.config.openai_api_base = nil
    Legion::Extensions::Llm.config.openai_organization_id = nil
    Legion::Extensions::Llm.config.openai_project_id = nil
  end

  def model_info(id, capabilities: %i[completion streaming], context_length: 128_000)
    Legion::Extensions::Llm::Model::Info.new(
      id: id,
      name: id,
      provider: :openai,
      capabilities: capabilities,
      context_length: context_length
    )
  end

  describe '#discover_offerings with CapabilityPolicy' do
    before do
      allow(credential_sources).to receive(:setting).with(:extensions, :llm, :openai).and_return({})
    end

    context 'when gpt-5 model gets capabilities from :provider_catalog source' do
      let(:gpt5_model) do
        model_info('gpt-5-turbo',
                   capabilities: %i[completion streaming function_calling tools vision structured_output reasoning])
      end

      before do
        allow(provider).to receive(:list_models).and_return([gpt5_model])
      end

      it 'resolves capabilities via provider_catalog' do
        offerings = provider.discover_offerings(live: true)
        expect(offerings.size).to eq(1)

        offering = offerings.first
        expect(offering.capabilities).to include(:streaming, :tools, :vision, :structured_output, :thinking)
        expect(offering.capability_sources[:streaming]).to eq({ value: true, source: :provider_catalog })
        expect(offering.capability_sources[:tools]).to eq({ value: true, source: :provider_catalog })
        expect(offering.capability_sources[:vision]).to eq({ value: true, source: :provider_catalog })
        expect(offering.capability_sources[:thinking]).to eq({ value: true, source: :provider_catalog })
        expect(offering.capability_sources[:structured_output]).to eq({ value: true, source: :provider_catalog })
      end
    end

    context 'when provider-root override disables capabilities broadly' do
      let(:gpt5_model) do
        model_info('gpt-5-turbo',
                   capabilities: %i[completion streaming function_calling tools vision structured_output reasoning])
      end

      before do
        allow(credential_sources).to receive(:setting)
          .with(:extensions, :llm, :openai)
          .and_return({ capabilities: { thinking: false, embeddings: false } })
        allow(provider).to receive(:list_models).and_return([gpt5_model])
      end

      it 'disables thinking and embeddings via provider_override' do
        offerings = provider.discover_offerings(live: true)
        offering = offerings.first

        expect(offering.capabilities).not_to include(:thinking)
        expect(offering.capabilities).not_to include(:embedding)
        expect(offering.capability_sources[:thinking]).to eq({ value: false, source: :provider_override })
        expect(offering.capability_sources[:embedding]).to eq({ value: false, source: :provider_override })
      end
    end

    context 'when instance override re-enables a flag disabled by provider' do
      let(:gpt5_model) do
        model_info('gpt-5-turbo',
                   capabilities: %i[completion streaming function_calling tools vision structured_output reasoning])
      end

      before do
        allow(credential_sources).to receive(:setting)
          .with(:extensions, :llm, :openai)
          .and_return({ capabilities: { thinking: false } })
        # Simulate instance config having enable_thinking = true
        allow(Legion::Extensions::Llm.config).to receive(:respond_to?).and_call_original
        allow(Legion::Extensions::Llm.config).to receive(:respond_to?).with(:enable_thinking).and_return(true)
        allow(Legion::Extensions::Llm.config).to receive(:enable_thinking).and_return(true)
        allow(provider).to receive(:list_models).and_return([gpt5_model])
      end

      it 're-enables thinking via instance_override' do
        offerings = provider.discover_offerings(live: true)
        offering = offerings.first

        expect(offering.capabilities).to include(:thinking)
        expect(offering.capability_sources[:thinking]).to eq({ value: true, source: :instance_override })
      end
    end

    context 'when model override forces a single model differently' do
      let(:gpt4o_model) do
        model_info('gpt-4o-mini',
                   capabilities: %i[completion streaming function_calling tools vision structured_output])
      end

      before do
        allow(credential_sources).to receive(:setting)
          .with(:extensions, :llm, :openai)
          .and_return({})
        allow(Legion::Extensions::Llm.config).to receive(:respond_to?).and_call_original
        allow(Legion::Extensions::Llm.config).to receive(:respond_to?).with(:models).and_return(true)
        allow(Legion::Extensions::Llm.config).to receive(:models).and_return(
          { 'gpt-4o-mini' => { capabilities: { vision: false, thinking: true } } }
        )
        allow(provider).to receive(:list_models).and_return([gpt4o_model])
      end

      it 'applies model_override to force capabilities' do
        offerings = provider.discover_offerings(live: true)
        offering = offerings.first

        expect(offering.capabilities).not_to include(:vision)
        expect(offering.capabilities).to include(:thinking)
        expect(offering.capability_sources[:vision]).to eq({ value: false, source: :model_override })
        expect(offering.capability_sources[:thinking]).to eq({ value: true, source: :model_override })
      end
    end
  end
end
