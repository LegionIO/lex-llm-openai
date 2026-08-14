# frozen_string_literal: true

require 'spec_helper'

module Legion
  module Extensions
    module Actors
      unless const_defined?(:Subscription, false)
        class Subscription
          def initialize(*) = true
        end
      end
    end
  end
end

require 'legion/extensions/llm/openai/actors/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Openai::Actor::FleetWorker do
  subject(:actor) { described_class.new }

  it 'uses the logging helper for actor diagnostics' do
    expect(described_class.ancestors).to include(Legion::Logging::Helper)
  end

  it 'uses the provider-owned fleet runner' do
    expect(actor.runner_class).to eq('Legion::Extensions::Llm::Openai::Runners::FleetWorker')
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })

    expect(actor.enabled?).to be(true)
  end

  it 'treats enablement errors as disabled after structured exception handling' do
    allow(Legion::Extensions::Llm::Openai).to receive(:discover_instances).and_raise(StandardError, 'boom')

    expect(actor.enabled?).to be(false)
  end
end
