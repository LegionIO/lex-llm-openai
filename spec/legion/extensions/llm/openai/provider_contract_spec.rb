# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/openai/provider'

RSpec.describe Legion::Extensions::Llm::Openai::Provider do
  # 0.8.0 funnel law (08 F1/F3): chat/stream_chat take positional canonical
  # messages plus keyword model/params — the provider must not shadow the
  # base funnel signature with a non-canonical one.
  it 'keeps the 0.8.0 completion funnel signature (positional canonical messages, keyword model)' do
    %i[chat stream_chat].each do |method_name|
      params = described_class.instance_method(method_name).parameters
      expect(params.first).to eq(%i[req messages]),
                              "#{method_name} must take positional canonical messages per the 0.8.0 funnel"
      expect(params).to include(%i[keyreq model])
    end
  end

  it 'does not expose positional text or prompt on the one-shot ops' do
    embed_params = described_class.instance_method(:embed).parameters
    expect(embed_params).not_to include(%i[req text])
    expect(embed_params).not_to include(%i[opt text])

    image_params = described_class.instance_method(:image).parameters
    expect(image_params).not_to include(%i[req prompt])
    expect(image_params).not_to include(%i[opt prompt])
  end
end
