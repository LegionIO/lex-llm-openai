# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/openai/chatgpt/translator'
require 'legion/extensions/llm/openai/chatgpt/stream_decoder'

RSpec.describe Legion::Extensions::Llm::Openai::Chatgpt::Translator do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:error_class) { Legion::Extensions::Llm::Openai::Chatgpt::Error }
  let(:translator) { described_class.new }
  let(:defaults) { { model: 'exact-model', tools: {}, params: nil, schema: nil, thinking: nil, tool_prefs: nil } }

  it 'renders system instructions, literal text, and input images without a Chat Completions intermediate' do
    messages = [
      canonical::Message.build(role: :system, content: 'Keep exact meaning'),
      canonical::Message.build(role: :user, content: [
                                 canonical::ContentBlock.text('Look'),
                                 canonical::ContentBlock.image(data: 'Zml4dHVyZQ==',
                                                               media_type: 'image/png', detail: 'high')
                               ])
    ]
    wire = translator.render(messages: messages, **defaults)
    expect(wire[:input]).to eq([
                                 { type: 'message', role: 'developer',
                                   content: [{ type: 'input_text', text: 'Keep exact meaning' }] },
                                 { type: 'message', role: 'user', content: [
                                   { type: 'input_text', text: 'Look' },
                                   { type: 'input_image', image_url: 'data:image/png;base64,Zml4dHVyZQ==',
                                     detail: 'high' }
                                 ] }
                               ])
  end

  it 'keeps interleaved parallel tool results correlated to their original IDs' do
    calls = [canonical::ToolCall.build(id: 'call_first', name: 'lookup', arguments: { key: 'one' }),
             canonical::ToolCall.build(id: 'call_second', name: 'lookup', arguments: { key: 'two' })]
    messages = [canonical::Message.build(role: :assistant, tool_calls: calls),
                canonical::Message.build(role: :tool, tool_call_id: 'call_second', content: 'two-result'),
                canonical::Message.build(role: :tool, tool_call_id: 'call_first', content: 'one-result')]
    wire = translator.render(messages: messages, **defaults)
    expect(wire[:input].map { |item| [item[:type], item[:call_id]] }).to eq(
      [%w[function_call call_first], %w[function_call call_second],
       %w[function_call_output call_second], %w[function_call_output call_first]]
    )
  end

  it 'keeps a tool-result block followed by user text in its original turn order' do
    call = canonical::ToolCall.build(id: 'call_exact', name: 'lookup')
    messages = [canonical::Message.build(role: :assistant, tool_calls: [call]),
                canonical::Message.build(role: :user, content: [
                                           canonical::ContentBlock.tool_result(tool_use_id: 'call_exact',
                                                                               content: 'found'),
                                           canonical::ContentBlock.text('Explain it')
                                         ])]
    wire = translator.render(messages: messages, **defaults)
    expect(wire[:input].last(2)).to eq([
                                         { type: 'function_call_output', call_id: 'call_exact', output: 'found' },
                                         { type: 'message', role: 'user',
                                           content: [{ type: 'input_text', text: 'Explain it' }] }
                                       ])
  end

  it 'refuses to invent missing tool results or turn orphan results into user prose' do
    call = canonical::ToolCall.build(id: 'call_exact', name: 'lookup')
    unresolved = [canonical::Message.build(role: :assistant, tool_calls: [call])]
    orphan = [canonical::Message.build(role: :tool, tool_call_id: 'call_exact', content: 'orphan')]
    expect { translator.render(messages: unresolved, **defaults) }.to raise_error(error_class)
    expect { translator.render(messages: orphan, **defaults) }.to raise_error(error_class)
  end

  it 'rejects malformed IDs instead of lossy sanitization' do
    call = canonical::ToolCall.build(id: 'original/id', name: 'lookup')
    messages = [canonical::Message.build(role: :assistant, tool_calls: [call]),
                canonical::Message.build(role: :tool, tool_call_id: 'original/id', content: 'result')]
    expect { translator.render(messages: messages, **defaults) }.to raise_error(error_class)
  end

  it 'represents named and parallel tool choices without changing the function schema' do
    schema = { type: 'object', properties: { value: { type: 'integer' } }, required: ['value'],
               additionalProperties: false }
    tool = canonical::ToolDefinition.build(name: 'lookup', parameters: schema, metadata: { strict: true })
    wire = translator.render(messages: [canonical::Message.build(content: 'Call lookup')],
                             **defaults.merge(tools: { lookup: tool },
                                              tool_prefs: {
                                                choice: 'lookup', parallel_tool_calls: false
                                              }))
    expect(wire[:tools].first).to include(name: 'lookup', parameters: schema, strict: true)
    expect(wire).to include(tool_choice: { type: 'function', name: 'lookup' }, parallel_tool_calls: false)
  end

  it 'rejects explicit sampling, schemas, unknown controls, and budget approximations' do
    messages = [canonical::Message.build(content: 'prompt')]
    controls = [
      { params: canonical::Params.build(temperature: 1) },
      { params: canonical::Params.build(metadata: { service_tier: 'priority' }) },
      { schema: { type: 'object' } },
      { thinking: canonical::Thinking::Config.build(budget: 1024) },
      { thinking: canonical::Thinking::Config.build(enabled: false, effort: 'high') },
      { tool_prefs: { choice: 'missing-tool' } }
    ]
    controls.each do |control|
      expect { translator.render(messages: messages, **defaults.merge(control)) }.to raise_error(error_class) do |error|
        expect(error.kind).to eq(:invalid_request)
      end
    end
  end

  it 'maps explicit reasoning effort and disabled thinking without fabricating a budget' do
    messages = [canonical::Message.build(content: 'prompt')]
    wire = translator.render(messages: messages,
                             **defaults.merge(thinking: canonical::Thinking::Config.build(effort: 'high',
                                                                                          summary: :concise)))
    expect(wire[:reasoning]).to eq(effort: 'high', summary: 'concise')
    disabled = translator.render(messages: messages,
                                 **defaults.merge(thinking: canonical::Thinking::Config.build(enabled: false)))
    expect(disabled[:reasoning]).to eq(effort: 'none')
  end

  describe Legion::Extensions::Llm::Openai::Chatgpt::StreamDecoder do
    let(:error_class) { Legion::Extensions::Llm::Openai::Chatgpt::Error }

    it 'handles byte-split UTF-8 and CRLF while retaining visible think tags literally' do
      chunks = []
      decoder = described_class.new(model: 'exact-model') { |chunk| chunks << chunk }
      output = [{ type: 'message', id: 'msg_exact', role: 'assistant',
                  content: [{ type: 'output_text', text: '<think>café</think>' }] }]
      event = { type: 'response.completed',
                response: { id: 'resp_exact', model: 'exact-model', status: 'completed', output: output } }
      data = "data: #{Legion::JSON.dump(event)}\r\n\r\n"
      data.bytes.each { |byte| decoder.feed(bytes: byte.chr.force_encoding(Encoding::UTF_8)) }
      response = decoder.finish
      expect(response.text).to eq('<think>café</think>')
      expect(response.thinking).to be_nil
      expect(chunks.select(&:text_delta?).map(&:delta).join).to eq(response.text)
    end

    it 'rejects a final snapshot contradicting already delivered text' do
      decoder = described_class.new(model: 'exact-model')
      item = { type: 'message', id: 'msg_exact', role: 'assistant', content: [] }
      events = [
        { type: 'response.output_item.added', output_index: 0, item: item },
        { type: 'response.output_text.delta', output_index: 0, item_id: 'msg_exact', content_index: 0,
          delta: 'original' },
        { type: 'response.completed', response: {
          id: 'resp_exact', model: 'exact-model', status: 'completed',
          output: [item.merge(content: [{ type: 'output_text', text: 'replacement' }])]
        } }
      ]
      expect do
        events.each { |event| decoder.feed(bytes: "data: #{Legion::JSON.dump(event)}\n\n") }
      end.to raise_error(error_class) { |error| expect(error.kind).to eq(:malformed_output) }
    end

    it 'rejects missing completion, failed completion, malformed JSON, and model substitution' do
      cases = [
        "data: [DONE]\n\n",
        "data: {broken}\n\n",
        "data: #{Legion::JSON.dump(type: 'response.incomplete',
                                   response: { id: 'resp_exact',
                                               status: 'incomplete' })}\n\n",
        "data: #{Legion::JSON.dump(type: 'response.completed',
                                   response: { id: 'resp_exact', model: 'replacement',
                                               status: 'completed', output: [] })}\n\n"
      ]
      cases.each do |data|
        decoder = described_class.new(model: 'exact-model')
        expect do
          decoder.feed(bytes: data)
          decoder.finish
        end.to raise_error(error_class)
      end
    end
  end
end
