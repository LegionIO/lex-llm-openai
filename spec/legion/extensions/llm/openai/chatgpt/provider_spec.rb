# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/openai/chatgpt/provider'
require_relative '../../../../../support/chatgpt_http_fixture'

RSpec.describe Legion::Extensions::Llm::Openai::Chatgpt::Provider do
  def canonical = Legion::Extensions::Llm::Canonical
  def error_class = Legion::Extensions::Llm::Openai::Chatgpt::Error
  def auth = Legion::Extensions::Llm::Openai::Chatgpt::Auth
  def model = 'fixture-exact-model'

  def binding
    { instance: 'Personal Exact', expected_account_id: 'fixture-account', expected_workspace_id: nil }
  end

  let(:providers) { [] }
  let(:fixture) { ChatgptHttpFixture.new }
  let(:config) do
    { instance_id: +'Personal Exact', auth_mode: :chatgpt, account_id: +'fixture-account', workspace_id: nil,
      request_timeout: 3, retry_interval: 0, retry_interval_randomness: 0, retry_backoff_factor: 1, max_retries: 4 }
  end
  let(:provider) do
    described_class.new(config).tap do |instance|
      providers << instance
      instance.connection.connection.url_prefix = fixture.url
    end
  end

  def credentials
    { access_token: 'fixture-access', account_id: 'fixture-account', workspace_id: nil, residency: 'eu' }
  end

  def messages
    [canonical::Message.build(role: :user, content: 'fixture prompt')]
  end

  def text_item
    { type: 'message', id: 'msg_fixture', role: 'assistant', status: 'completed',
      content: [{ type: 'output_text', text: 'Hello café' }] }
  end

  def usage
    { input_tokens: 12, output_tokens: 8, input_tokens_details: { cached_tokens: 4 },
      output_tokens_details: { reasoning_tokens: 3 } }
  end

  before do
    allow(Legion::Settings).to receive(:dig).and_call_original
    allow(Legion::Settings).to receive(:dig).with(:extensions, :llm, :ssl, :verify).and_return(true)
    allow(auth).to receive(:credentials).with(**binding).and_return(credentials)
  end

  after do
    providers.each(&:disconnect)
    fixture.close
  end

  def event(value:)
    # Multiple data lines are one JSON event, including CRLF and comments.
    json = Legion::JSON.dump(value).sub(',', ",\r\ndata: ")
    ": keepalive\r\nevent: #{value[:type]}\r\ndata: #{json}\r\n\r\n"
  end

  def completed_stream(output:, deltas: [])
    event(value: { type: 'response.created', response: { id: 'resp_fixture', model: model, status: 'in_progress' } }) +
      deltas.map { |value| event(value: value) }.join +
      event(value: { type: 'response.completed',
                     response: { id: 'resp_fixture', model: model, status: 'completed', output: output,
                                 usage: usage } })
  end

  def reasoning
    { type: 'reasoning', id: 'rs_fixture', summary: [{ type: 'summary_text', text: 'Plan.' }],
      encrypted_content: 'fixture-opaque' }
  end

  def tool_schema
    { type: 'object', properties: { key: { type: 'string' } } }
  end

  def tool_response_stream
    tool = { type: 'function_call', id: 'fc_fixture', call_id: 'call_exact', name: 'lookup',
             arguments: '{"key":"value"}', status: 'completed' }
    deltas = [
      { type: 'response.output_item.added', output_index: 0, item: reasoning.merge(summary: []) },
      { type: 'response.reasoning_summary_text.delta', output_index: 0, item_id: reasoning[:id], summary_index: 0,
        delta: 'Plan.' },
      { type: 'response.output_item.added', output_index: 1, item: tool.merge(arguments: '', status: 'in_progress') },
      { type: 'response.function_call_arguments.delta', output_index: 1, item_id: tool[:id], delta: '{"key":' },
      { type: 'response.function_call_arguments.delta', output_index: 1, item_id: tool[:id], delta: '"value"}' }
    ]
    completed_stream(output: [reasoning, tool], deltas: deltas)
  end

  def text_deltas
    [
      { type: 'response.output_item.added', output_index: 0,
        item: text_item.merge(status: 'in_progress', content: []) },
      { type: 'response.output_text.delta', output_index: 0, item_id: text_item[:id], content_index: 0,
        delta: 'Hello ' },
      { type: 'response.output_text.delta', output_index: 0, item_id: text_item[:id], content_index: 0, delta: 'café' }
    ]
  end

  it 'executes ordinary and streaming calls through the same multiline, chunked SSE boundary' do
    2.times { fixture.reply(body: completed_stream(output: [text_item], deltas: text_deltas)) }
    ordinary = provider.complete(messages, model: model)
    chunks = []
    streamed = provider.complete(messages, model: model) { |chunk| chunks << chunk }
    expect(ordinary).to be_a(canonical::Response)
    expect(streamed).to eq(ordinary)
    expect(chunks).to all(be_a(canonical::Chunk))
    expect(chunks.select(&:text_delta?).map(&:delta).join).to eq(ordinary.text)
    expect(ordinary.text).to eq('Hello café')
    expect(chunks.count(&:done?)).to eq(1)
    expect(ordinary.usage.to_h).to include(input_tokens: 12, output_tokens: 8, cache_read_tokens: 4, thinking_tokens: 3)
    request = fixture.requests.pop
    payload = Legion::JSON.load(request[:body])
    expect(request[:path]).to eq('/backend-api/codex/responses')
    expect(request[:headers]).to include(
      'authorization' => 'Bearer fixture-access', 'chatgpt-account-id' => 'fixture-account',
      'x-openai-internal-codex-residency' => 'eu', 'originator' => 'legion', 'version' => '0.159.0'
    )
    expect(payload).to include(model: model, stream: true, store: false)
    expect(auth).to have_received(:credentials).with(**binding).twice
  end

  it 'preserves tool correlation and opaque reasoning through a second real request' do
    fixture.reply(body: tool_response_stream)
    fixture.reply(body: completed_stream(output: [text_item]))
    tools = { lookup: canonical::ToolDefinition.build(name: 'lookup', parameters: tool_schema) }
    chunks = []
    first = provider.complete(messages, model: model, tools: tools) { |chunk| chunks << chunk }
    expect(first.text).to eq('')
    expect(first.thinking.content).to eq('Plan.')
    expect(first.thinking.signature).to eq('fixture-opaque')
    expect(first.tool_calls.first).to have_attributes(id: 'call_exact', arguments: { key: 'value' })
    expect(chunks.select(&:thinking_delta?).map(&:delta).join).to eq(first.thinking.content)
    expect(chunks.select(&:thinking_delta?).map(&:signature)).to include('fixture-opaque')
    replay = messages + [
      canonical::Message.build(role: :assistant, tool_calls: first.tool_calls, metadata: first.metadata),
      canonical::Message.build(role: :tool, tool_call_id: 'call_exact', content: 'found')
    ]
    provider.complete(replay, model: model, tools: tools)
    fixture.requests.pop
    outbound = Legion::JSON.load(fixture.requests.pop[:body])[:input]
    expect(outbound).to include(reasoning)
    expect(outbound).to include(type: 'function_call', id: 'fc_fixture', call_id: 'call_exact', name: 'lookup',
                                arguments: '{"key":"value"}')
    expect(outbound).to include(type: 'function_call_output', call_id: 'call_exact', output: 'found')
  end

  it 'does not convert EOF after delivered output into successful completion or replay it' do
    body = event(value: { type: 'response.output_item.added', output_index: 0, item: text_item.merge(content: []) }) +
           event(value: { type: 'response.output_text.delta', output_index: 0, item_id: 'msg_fixture',
                          content_index: 0, delta: 'partial' })
    fixture.reply(body: body)
    chunks = []
    expect do
      provider.complete(messages, model: model) do |chunk|
        chunks << chunk
      end
    end.to raise_error(error_class) { |error|
             expect(error.kind).to eq(:malformed_output)
           }
    expect(chunks.select(&:text_delta?).map(&:delta).join).to eq('partial')
    expect(chunks.none?(&:done?)).to be(true)
    expect(fixture.requests.size).to eq(1)
  end

  it 'propagates callback cancellation without another request or completion' do
    fixture.reply(body: completed_stream(output: [text_item]))
    cancelled = Class.new(StandardError).new('cancel fixture')
    chunks = []
    expect do
      provider.complete(messages, model: model) do |chunk|
        chunks << chunk
        raise cancelled if chunk.text_delta?
      end
    end.to(raise_error { |error| expect(error).to equal(cancelled) })
    expect(chunks.none?(&:done?)).to be(true)
    expect(fixture.requests.size).to eq(1)
  end

  it 'rejects unsupported authoritative controls before credentials or HTTP' do
    expect do
      provider.complete(messages, model: model, params: canonical::Params.build(max_tokens: 20))
    end.to raise_error(error_class) { |error| expect(error.kind).to eq(:invalid_request) }
    expect(auth).not_to have_received(:credentials)
    expect(fixture.requests).to be_empty
  end

  it 'retains the strict base Canonical message and tool boundaries' do
    expect do
      provider.complete([{ role: 'user', content: 'not canonical' }], model: model)
    end.to raise_error(ArgumentError)
    expect do
      provider.complete(messages, model: model, tools: { lookup: { name: 'lookup' } })
    end.to raise_error(ArgumentError)
    expect(auth).not_to have_received(:credentials)
    expect(fixture.requests).to be_empty
  end

  it 'refuses a replaced account or workspace without HTTP or another account' do
    allow(auth).to receive(:credentials).with(**binding)
                                        .and_return(credentials.merge(workspace_id: 'another-workspace'))
    expect { provider.complete(messages, model: model) }.to raise_error(error_class) { |error|
      expect(error.kind).to eq(:authentication)
    }
    expect(fixture.requests).to be_empty
  end

  it 'keeps the original identity binding when its caller mutates configuration' do
    instance = provider
    config[:account_id].replace('changed-account')
    config[:instance_id].replace('changed-instance')
    fixture.reply(body: completed_stream(output: [text_item]))
    expect(instance.complete(messages, model: model).text).to eq('Hello café')
    expect(auth).to have_received(:credentials).with(**binding)
  end

  it 'requires verified shared TLS before touching credentials' do
    allow(Legion::Settings).to receive(:dig).with(:extensions, :llm, :ssl, :verify).and_return(false)
    expect { described_class.new(config) }.to raise_error(Legion::Extensions::Llm::ConfigurationError)
    expect(auth).not_to have_received(:credentials)
  end

  it 'does not accept an arbitrary upstream origin' do
    expect do
      described_class.new(config.merge(openai_api_base: 'https://untrusted.invalid'))
    end.to raise_error(Legion::Extensions::Llm::ConfigurationError)
  end

  it 'preserves exact catalog IDs and evidence without fabricating aliases or limits' do
    rows = [{ slug: 'fixture-wm', context_window: 100_000, input_modalities: %w[text image] },
            { id: 'fixture-unknown-limits' }]
    fixture.reply(body: Legion::JSON.dump(models: rows), content_type: 'application/json')
    expect(provider.catalog).to eq([rows.first.merge(id: 'fixture-wm'), rows.last])
    expect(fixture.requests.pop[:path]).to eq('/backend-api/codex/models?client_version=0.159.0')
  end

  it 'does not publish account catalog entries explicitly hidden upstream' do
    rows = [{ slug: 'visible' }, { slug: 'retired', visibility: 'hide' }, { slug: 'internal', visibility: 'hidden' }]
    fixture.reply(body: Legion::JSON.dump({ models: rows }), content_type: 'application/json')
    expect(provider.catalog).to eq([{ slug: 'visible', id: 'visible' }])
  end

  it 'rejects a successful HTTP response with no catalog schema' do
    fixture.reply(body: '{"unexpected":[]}', content_type: 'application/json')
    expect { provider.catalog }.to raise_error(error_class) { |error| expect(error.kind).to eq(:malformed_output) }
  end

  it 'preserves quota reset facts without exposing upstream body or token text' do
    body = Legion::JSON.dump(error: { type: 'usage_limit_reached', resets_in_seconds: 120,
                                      message: 'secret fixture-access' })
    fixture.reply(body: body, status: 429, content_type: 'application/json',
                  headers: { 'Retry-After' => '90', 'x-codex-primary-used-percent' => '100',
                             'x-codex-primary-reset-at' => '2000000000', 'x-codex-secondary-used-percent' => '20' })
    expect { provider.complete(messages, model: model) }.to raise_error(error_class) do |error|
      expect(error.kind).to eq(:rate_limited)
      expect(error.retry_after).to eq(90)
      expect(error.metadata).to include(code: 'usage_limit_reached', resets_in_seconds: 120)
      expect(error.metadata[:rate_limits]).to eq(primary: { used_percent: 100, resets_at: 2_000_000_000 },
                                                 secondary: { used_percent: 20 })
      expect([error.message, error.metadata.inspect, error.cause].join).not_to include('fixture-access')
    end
    expect(fixture.requests.size).to eq(1)
  end
end
