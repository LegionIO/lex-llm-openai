# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Openai::Translator do
  subject(:translator) { described_class.new }

  describe 'conformance' do
    it_behaves_like 'a canonical provider translator', described_class
  end

  describe '#render_request' do
    let(:canonical_request) do
      Legion::Extensions::Llm::Canonical::Request.build(
        id: 'test-req',
        routing: { model: 'gpt-4o' },
        messages: [
          Legion::Extensions::Llm::Canonical::Message.build(
            role: :user,
            content: 'Hello'
          )
        ],
        params: Legion::Extensions::Llm::Canonical::Params.build(
          max_tokens: 100,
          temperature: 0.5,
          top_p: 0.9,
          top_k: 40,
          stop_sequences: ['STOP'],
          seed: 42,
          frequency_penalty: 0.1,
          presence_penalty: 0.2,
          response_format: { type: 'json_object' },
          max_thinking_tokens: nil
        )
      )
    end

    it 'renders model, messages, and stream flag' do
      wire = translator.render_request(canonical_request)
      expect(wire).to include(model: 'gpt-4o', stream: false)
      expect(wire[:messages]).to be_an(Array)
      expect(wire[:messages].first[:role]).to eq('user')
    end

    it 'maps max_tokens and temperature' do
      wire = translator.render_request(canonical_request)
      expect(wire[:max_tokens]).to eq(100)
      expect(wire[:temperature]).to eq(0.5)
      expect(wire[:top_p]).to eq(0.9)
    end

    it 'drops top_k with a debug log' do
      wire = translator.render_request(canonical_request)
      expect(wire).not_to have_key(:top_k)
    end

    it 'maps stop_sequences to stop array' do
      wire = translator.render_request(canonical_request)
      expect(wire[:stop]).to eq(['STOP'])
    end

    it 'preserves seed and penalties' do
      wire = translator.render_request(canonical_request)
      expect(wire[:seed]).to eq(42)
      expect(wire[:frequency_penalty]).to eq(0.1)
      expect(wire[:presence_penalty]).to eq(0.2)
    end

    it 'renders response_format' do
      wire = translator.render_request(canonical_request)
      expect(wire[:response_format]).to eq({ type: 'json_object' })
    end

    context 'with tools' do
      let(:canonical_request) do
        Legion::Extensions::Llm::Canonical::Request.build(
          routing: { model: 'gpt-4o' },
          messages: [
            Legion::Extensions::Llm::Canonical::Message.build(
              role: :user,
              content: 'test'
            )
          ],
          tools: {
            get_weather: Legion::Extensions::Llm::Canonical::ToolDefinition.build(
              name: 'get_weather',
              description: 'Get weather',
              parameters: { type: 'object', properties: { location: { type: 'string' } } }
            )
          }
        )
      end

      it 'renders tools in OpenAI format' do
        wire = translator.render_request(canonical_request)
        expect(wire[:tools]).to be_an(Array)
        func = wire[:tools].first[:function]
        expect(func[:name]).to eq('get_weather')
        expect(func[:description]).to eq('Get weather')
      end
    end

    context 'with thinking config' do
      let(:canonical_request) do
        Legion::Extensions::Llm::Canonical::Request.build(
          routing: { model: 'gpt-4o' },
          messages: [
            Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'test')
          ],
          thinking: Legion::Extensions::Llm::Canonical::Thinking::Config.build(
            effort: 'high'
          )
        )
      end

      it 'renders reasoning_effort' do
        wire = translator.render_request(canonical_request)
        expect(wire[:reasoning_effort]).to eq('high')
      end
    end

    context 'with streaming' do
      let(:canonical_request) do
        Legion::Extensions::Llm::Canonical::Request.build(
          routing: { model: 'gpt-4o' },
          messages: [
            Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'test')
          ],
          stream: true
        )
      end

      it 'includes stream_options' do
        wire = translator.render_request(canonical_request)
        expect(wire[:stream_options]).to eq(include_usage: true)
      end
    end

    context 'with system prompt' do
      let(:canonical_request) do
        Legion::Extensions::Llm::Canonical::Request.build(
          routing: { model: 'gpt-4o' },
          system: 'Be helpful.',
          messages: [
            Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'test')
          ]
        )
      end

      it 'renders system message first' do
        wire = translator.render_request(canonical_request)
        first_msg = wire[:messages].first
        expect(first_msg[:role]).to eq('system')
        expect(first_msg[:content]).to eq('Be helpful.')
      end
    end
  end

  describe '#parse_response' do
    context 'with OpenAI wire format' do
      it 'parses text response' do
        wire = {
          'model' => 'gpt-4',
          'choices' => [{ 'message' => { 'content' => 'Hello world' }, 'finish_reason' => 'stop' }],
          'usage' => { 'prompt_tokens' => 10, 'completion_tokens' => 5 }
        }

        result = translator.parse_response(wire)
        expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
        expect(result.text).to eq('Hello world')
        expect(result.stop_reason).to eq(:end_turn)
        expect(result.model).to eq('gpt-4')
        expect(result.usage.input_tokens).to eq(10)
        expect(result.usage.output_tokens).to eq(5)
      end

      it 'parses tool call response' do
        wire = {
          'model' => 'gpt-4',
          'choices' => [{
            'message' => {
              'content' => '',
              'tool_calls' => [{
                'id' => 'call_123',
                'function' => { 'name' => 'get_weather', 'arguments' => '{"location":"NYC"}' }
              }]
            },
            'finish_reason' => 'tool_calls'
          }],
          'usage' => { 'prompt_tokens' => 20, 'completion_tokens' => 30 }
        }

        result = translator.parse_response(wire)
        expect(result.stop_reason).to eq(:tool_use)
        expect(result.tool_calls).to be_an(Array)
        expect(result.tool_calls.first.name).to eq('get_weather')
        expect(result.tool_calls.first.arguments[:location]).to eq('NYC')
        expect(result.tool_calls.first.source).to eq(:client)
      end

      it 'maps finish_reasons' do
        %w[length content_filter].each do |reason|
          wire = {
            'model' => 'gpt-4',
            'choices' => [{ 'message' => { 'content' => '' }, 'finish_reason' => reason }],
            'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 }
          }

          expected = reason == 'length' ? :max_tokens : :content_filter
          expect(translator.parse_response(wire).stop_reason).to eq(expected)
        end
      end
    end

    context 'with thinking metadata' do
      it 'extracts reasoning_content and thinking signature' do
        wire = {
          'model' => 'gpt-5',
          'choices' => [{
            'message' => {
              'content' => 'Answer',
              'reasoning_content' => 'Let me think...',
              'thinking_signature' => 'sig123'
            },
            'finish_reason' => 'stop'
          }],
          'usage' => {
            'prompt_tokens' => 10,
            'completion_tokens' => 20,
            'completion_tokens_details' => { 'reasoning_tokens' => 15 }
          }
        }

        result = translator.parse_response(wire)
        expect(result.text).to eq('Answer')
        expect(result.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking)
        expect(result.thinking.content).to include('think')
        expect(result.thinking.signature).to eq('sig123')
      end
    end
  end

  describe '#parse_chunk' do
    context 'with text delta' do
      it 'returns text_delta chunk' do
        raw = {
          'id' => 'chatcmpl-1',
          'choices' => [{ 'delta' => { 'content' => 'Hello' } }]
        }

        result = translator.parse_chunk(raw)
        expect(result).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
        expect(result.type).to eq(:text_delta)
        expect(result.delta).to eq('Hello')
        expect(result.request_id).to eq('chatcmpl-1')
      end
    end

    context 'with reasoning delta' do
      it 'returns thinking_delta chunk' do
        raw = {
          'id' => 'chatcmpl-1',
          'choices' => [{ 'delta' => { 'reasoning_content' => 'Thinking...' } }]
        }

        result = translator.parse_chunk(raw)
        expect(result.type).to eq(:thinking_delta)
        expect(result.delta).to eq('Thinking...')
      end
    end

    context 'with done chunk' do
      it 'returns done chunk with stop reason' do
        raw = {
          'id' => 'chatcmpl-1',
          'choices' => [{ 'finish_reason' => 'stop' }],
          'usage' => { 'prompt_tokens' => 10, 'completion_tokens' => 20 }
        }

        result = translator.parse_chunk(raw)
        expect(result.type).to eq(:done)
        expect(result.stop_reason).to eq(:end_turn)
      end
    end

    context 'with error chunk' do
      it 'returns error chunk' do
        raw = {
          'id' => 'chatcmpl-1',
          'error' => { 'message' => 'Rate limited' }
        }

        result = translator.parse_chunk(raw)
        expect(result.type).to eq(:error)
        expect(result.error?).to be true
      end
    end

    context 'with nil/raw' do
      it 'returns nil for nil' do
        expect(translator.parse_chunk(nil)).to be_nil
      end

      it 'returns nil for empty hash' do
        expect(translator.parse_chunk({})).to be_nil
      end
    end
  end

  describe '#parse_response usage with nested cached_tokens' do
    it 'extracts cache_read_tokens from prompt_tokens_details (Chat API)' do
      wire = {
        'model' => 'gpt-4o',
        'choices' => [{ 'message' => { 'content' => 'Hi' }, 'finish_reason' => 'stop' }],
        'usage' => {
          'prompt_tokens' => 1000,
          'completion_tokens' => 50,
          'prompt_tokens_details' => { 'cached_tokens' => 800 },
          'completion_tokens_details' => { 'reasoning_tokens' => 20 }
        }
      }

      result = translator.parse_response(wire)
      expect(result.usage.input_tokens).to eq(1000)
      expect(result.usage.output_tokens).to eq(50)
      expect(result.usage.cache_read_tokens).to eq(800)
      expect(result.usage.thinking_tokens).to eq(20)
    end

    it 'extracts cache_read_tokens from input_tokens_details (Responses API)' do
      wire = {
        'model' => 'gpt-4o',
        'choices' => [{ 'message' => { 'content' => 'Hi' }, 'finish_reason' => 'stop' }],
        'usage' => {
          'input_tokens' => 500,
          'output_tokens' => 100,
          'input_tokens_details' => { 'cached_tokens' => 400 },
          'output_tokens_details' => { 'reasoning_tokens' => 30 }
        }
      }

      result = translator.parse_response(wire)
      expect(result.usage.input_tokens).to eq(500)
      expect(result.usage.output_tokens).to eq(100)
      expect(result.usage.cache_read_tokens).to eq(400)
      expect(result.usage.thinking_tokens).to eq(30)
    end

    it 'works with symbol-keyed usage (from Legion::JSON.load)' do
      wire = {
        'model' => 'gpt-4o',
        'choices' => [{ 'message' => { 'content' => 'Hi' }, 'finish_reason' => 'stop' }],
        'usage' => {
          prompt_tokens: 600,
          completion_tokens: 80,
          prompt_tokens_details: { cached_tokens: 500 }
        }
      }

      result = translator.parse_response(wire)
      expect(result.usage.cache_read_tokens).to eq(500)
    end
  end
end
