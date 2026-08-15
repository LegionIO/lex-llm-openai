# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/openai/runners/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Openai::Runners::FleetWorker do
  let(:envelope) { { request_id: 'req-1', provider: 'openai', provider_instance: 'local' } }
  let(:instances) { { local: { fleet: { respond_to_requests: true } } } }

  it 'uses the logging helper for fleet diagnostics' do
    expect(described_class.singleton_class.ancestors).to include(Legion::Logging::Helper)
  end

  it 'accepts the fleet envelope as kwargs (Subscription dispatch shape)' do
    expect(described_class.method(:handle_fleet_request).parameters).to include(%i[keyrest envelope])
  end

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances).and_return(instances)
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    result = described_class.handle_fleet_request(**envelope)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload: envelope,
      provider_family: :openai,
      provider_class: Legion::Extensions::Llm::Openai::Provider,
      provider_instances: satisfy { |resolver| resolver.call == instances }
    )
  end
end
