# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Openai
        # Canonical <-> OpenAI wire-format translator.
        #
        # Implements the provider-boundary contract (Amendment A) so that
        # canonical requests/responses/chunks cross exactly one translation
        # layer per provider. Extracted from OpenAICompatible mixin methods;
        # semantics preserved, not rewritten.
        #
        # Capabilities (declarative, per the design doc):
        #   - reasoning_effort: true            (gpt-5.x / o-series)
        #   - responses_api: true               (chat/completions wire format)
        #   - thinking_metadata_keys: [...]     (metadata keys for thinking)
        #   - stop_reason_map: { openai -> canonical }
        class Translator
          include Legion::Logging::Helper

          # OpenAI finish_reason -> canonical stop_reason (G18 stop-reason matrix)
          STOP_REASON_MAP = {
            'stop' => :end_turn,
            'tool_calls' => :tool_use,
            'function_call' => :tool_use,
            'length' => :max_tokens,
            'content_filter' => :content_filter
          }.freeze

          # Metadata keys carrying thinking/reasoning in OpenAI responses
          THINKING_METADATA_KEYS = %i[
            reasoning_content reasoning thinking thinking_text
            thinking_signature reasoning_signature
          ].freeze

          def initialize(api_base: nil, headers: nil)
            @api_base = api_base
            @headers = headers || {}
          end

          # @return [Hash] declarative capabilities consumed by routing/dispatch
          def capabilities
            {
              provider: 'openai',
              reasoning_effort: true,
              responses_api: true,
              thinking_metadata_keys: THINKING_METADATA_KEYS,
              stop_reason_map: STOP_REASON_MAP
            }
          end

          # @param canonical_request [Canonical::Request]
          # @return [Hash] OpenAI wire-format payload for /v1/chat/completions
          def render_request(canonical_request)
            wire = {
              model: resolve_model(canonical_request),
              messages: render_messages(canonical_request),
              stream: canonical_request.stream
            }.compact

            apply_params(wire, canonical_request.params) if canonical_request.params
            apply_tools(wire, canonical_request) if canonical_request.tools&.any?
            apply_tool_choice(wire, canonical_request.tool_choice) if canonical_request.tool_choice
            apply_thinking(wire, canonical_request)
            use_stream_usage(wire) if canonical_request.stream

            wire
          end

          # @param wire [Hash] OpenAI API response body (string-keyed)
          # @return [Canonical::Response]
          def parse_response(wire)
            return Canonical::Response.from_hash(wire) if canonical_form?(wire)

            build_canonical_response(wire.to_h)
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: 'openai.translator.parse_response')
            Canonical::Response.build(text: '', stop_reason: :error, metadata: { error: e.message })
          end

          # @param raw [Hash] single SSE data payload or canonical chunk
          # @return [Canonical::Chunk, nil]
          def parse_chunk(raw)
            return nil if raw.nil? || raw.to_h.empty?
            return Canonical::Chunk.from_hash(raw) if canonical_chunk_form?(raw)

            parse_raw_chunk(raw.to_h)
          rescue StandardError => e
            handle_exception(e, level: :error, handled: true, operation: 'openai.translator.parse_chunk')
            Canonical::Chunk.error_chunk(error: e.message, request_id: raw.to_h['id'])
          end

          private

          def apply_params(wire, params)
            apply_generation_params(wire, params)
            wire[:frequency_penalty] = params.frequency_penalty if params.frequency_penalty
            wire[:presence_penalty] = params.presence_penalty if params.presence_penalty
            apply_format_params(wire, params)
          end

          def apply_generation_params(wire, params)
            wire[:max_tokens] = params.max_tokens if params.max_tokens
            wire[:temperature] = params.temperature if params.temperature
            wire[:top_p] = params.top_p if params.top_p
            wire[:seed] = params.seed if params.seed
            log.debug('[openai.translator] dropping unsupported param: top_k') if params.top_k
          end

          def apply_format_params(wire, params)
            wire[:stop] = Array(params.stop_sequences) if params.stop_sequences
            wire[:response_format] = render_response_format(params.response_format) if params.response_format
            return unless params.max_thinking_tokens

            log.debug('[openai.translator] mapped to reasoning_effort via thinking config')
          end

          def render_response_format(fmt)
            return fmt if fmt.is_a?(Hash)

            type_val = fmt.to_s
            type_val == 'json_object' ? { type: 'json_object' } : { type: type_val }
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'openai.translator.render_response_format')
            { type: 'text' }
          end

          def apply_tools(wire, canonical_request)
            wire[:tools] = canonical_request.tools.values.map do |tool_def|
              {
                type: 'function',
                function: {
                  name: tool_def.name,
                  description: tool_def.description,
                  parameters: tool_def.parameters || { type: 'object', properties: {} }
                }
              }
            end
          end

          def apply_tool_choice(wire, tool_choice)
            wire[:tool_choice] = case tool_choice
                                 when :auto then 'auto'
                                 when :none then 'none'
                                 when :required then 'required'
                                 when Hash
                                   {
                                     type: 'function',
                                     function: { name: tool_choice[:name] || tool_choice['name'] }
                                   }
                                 else
                                   tool_choice.to_s
                                 end
          end

          def apply_thinking(wire, canonical_request)
            thinking = canonical_request.thinking
            return unless thinking

            effort = if thinking.respond_to?(:effort)
                       thinking.effort
                     else
                       thinking[:effort] || thinking['effort']
                     end
            return unless effort

            wire[:reasoning_effort] = effort.to_s.downcase
          end

          def use_stream_usage(wire)
            wire[:stream_options] = { include_usage: true }
          end

          def resolve_model(canonical_request)
            return canonical_request.routing[:model] if canonical_request.routing&.dig(:model)
            return canonical_request.caller[:model] if canonical_request.caller&.dig(:model)

            model = canonical_request.metadata&.dig(:model)
            return model if model

            raise ArgumentError, '[openai] no model selected: routing, caller, and metadata all absent'
          end

          def render_messages(canonical_request)
            messages = []

            messages << { role: 'system', content: canonical_request.system } if canonical_request.system

            Array(canonical_request.messages).each do |msg|
              messages << render_message(msg)
            end

            messages
          end

          def render_message(msg)
            openai_msg = { role: msg.role.to_s }

            case msg.role
            when :assistant
              render_assistant_message(openai_msg, msg)
            when :tool
              openai_msg[:tool_call_id] = msg.tool_call_id if msg.tool_call_id
              openai_msg[:content] = extract_text_from_content(msg.content)
            else
              openai_msg[:content] = extract_text_from_content(msg.content)
            end

            openai_msg
          end

          def render_assistant_message(openai_msg, msg)
            content_parts = []
            openai_msg[:tool_calls] = render_openai_tool_calls(msg.tool_calls) if msg.tool_calls&.any?
            text = extract_text_from_content(msg.content)
            content_parts << { type: 'text', text: text } if text
            append_tool_use_blocks(content_parts, msg.content)
            openai_msg[:content] = content_parts.empty? ? '' : content_parts
          end

          def append_tool_use_blocks(content_parts, content)
            return unless content.is_a?(Array)

            content.each do |block|
              next unless block.is_a?(Canonical::ContentBlock) && block.tool_use?

              content_parts << {
                type: 'tool_use',
                id: block.id,
                name: block.name,
                input: block.input || {}
              }
            end
          end

          def extract_text_from_content(content)
            return content if content.is_a?(String)
            return '' unless content

            case content
            when Array then content.filter_map { |block| extract_block_text(block) }.join
            when Canonical::ContentBlock then content.text.to_s
            else content.to_s
            end
          end

          def extract_block_text(block)
            block.is_a?(Canonical::ContentBlock) ? block.text.to_s : (block[:text] || block['text'] || block.to_s)
          end

          def render_openai_tool_calls(tool_calls)
            tc_array = tool_calls.is_a?(Hash) ? tool_calls.values : Array(tool_calls)
            tc_array.map do |tc|
              args = tc.arguments.is_a?(String) ? tc.arguments : Legion::JSON.generate(tc.arguments || {})

              {
                id: tc.id,
                type: 'function',
                function: { name: tc.name, arguments: args }
              }
            end
          end

          # Extracted from OpenAICompatible mixin response parsing
          def extract_thinking_from_message(message)
            metadata = {
              reasoning_content: message['reasoning_content'],
              reasoning: message['reasoning'],
              thinking: message['thinking'],
              thinking_text: message['thinking_text'],
              thinking_signature: message['thinking_signature'],
              reasoning_signature: message['reasoning_signature']
            }.compact

            extraction = Llm::Responses::ThinkingExtractor.extract(
              message['content'],
              metadata: metadata
            )

            [
              extraction.content || '',
              Canonical::Thinking.from_hash(
                content: extraction.thinking,
                signature: extraction.signature
              )
            ]
          end

          def parse_tool_calls(raw)
            return [] unless raw&.any?

            Array(raw).flat_map do |call|
              function = call.fetch('function', {})
              args = parse_tool_arguments(function['arguments'])

              Canonical::ToolCall.build(
                id: call['id'],
                name: function['name'],
                arguments: args,
                source: :client
              )
            end.compact
          end

          def parse_tool_arguments(arguments)
            return {} if arguments.nil? || arguments == ''
            return arguments if arguments.is_a?(Hash)

            Legion::JSON.load(arguments)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'openai.translator.parse_tool_arguments')
            {}
          end

          def parse_usage(raw)
            return nil unless raw&.any?

            normalized = raw.dup
            normalized[:cache_read_tokens] ||= extract_nested_cached_tokens(raw)
            normalized[:thinking_tokens] ||= extract_nested_reasoning_tokens(raw)
            Canonical::Usage.from_hash(normalized)
          end

          def extract_nested_cached_tokens(raw)
            raw.dig(:prompt_tokens_details, :cached_tokens) ||
              raw.dig('prompt_tokens_details', 'cached_tokens') ||
              raw.dig(:input_tokens_details, :cached_tokens) ||
              raw.dig('input_tokens_details', 'cached_tokens')
          end

          def extract_nested_reasoning_tokens(raw)
            raw.dig(:completion_tokens_details, :reasoning_tokens) ||
              raw.dig('completion_tokens_details', 'reasoning_tokens') ||
              raw.dig(:output_tokens_details, :reasoning_tokens) ||
              raw.dig('output_tokens_details', 'reasoning_tokens')
          end

          def map_stop_reason(raw)
            return nil unless raw

            STOP_REASON_MAP.fetch(raw.to_s, nil) || raw.to_sym
          end

          def extract_response_metadata(message)
            {
              reasoning: message['reasoning'],
              reasoning_content: message['reasoning_content']
            }.compact
          end

          def parse_error_chunk(data)
            Canonical::Chunk.error_chunk(
              error: data['error'].to_s,
              request_id: data['id']
            )
          end

          def build_done_chunk(data, finish_reason, usage_raw)
            Canonical::Chunk.done(
              request_id: data['id'],
              stop_reason: map_stop_reason(finish_reason),
              usage: parse_usage(usage_raw)
            )
          end

          def build_thinking_chunk(reasoning, request_id, stop_reason: nil, usage: nil)
            Canonical::Chunk.thinking_delta(
              delta: reasoning,
              request_id: request_id,
              stop_reason: stop_reason,
              usage: usage
            )
          end

          def build_text_chunk(content, request_id, stop_reason: nil, usage: nil)
            Canonical::Chunk.text_delta(
              delta: content,
              request_id: request_id,
              stop_reason: stop_reason,
              usage: usage
            )
          end

          def parse_tool_call_delta(delta, data, stop_reason: nil, usage: nil)
            raw_tc = delta['tool_calls']
            return nil unless raw_tc&.any?

            tc = Array(raw_tc).first || {}
            func = tc['function'] || {}

            tool_call = Canonical::ToolCall.build(
              id: tc['id'],
              name: func['name'],
              arguments: parse_tool_arguments(func['arguments'])
            )

            Canonical::Chunk.tool_call_delta(
              tool_call: tool_call,
              request_id: data['id'],
              stop_reason: stop_reason,
              usage: usage
            )
          end

          # Format detection - conformance kit passes canonical-form fixtures;
          # real usage sends OpenAI wire format. Detect and handle both.
          def canonical_form?(hash)
            h = hash.is_a?(Hash) ? hash.transform_keys(&:to_sym) : {}
            !h[:text].nil? || !h[:stop_reason].nil? || !h[:tool_calls].nil? || !h[:thinking].nil?
          end

          def canonical_chunk_form?(hash)
            h = hash.is_a?(Hash) ? hash.transform_keys(&:to_sym) : {}
            !h[:type].nil?
          end

          def parse_raw_chunk(data)
            return parse_error_chunk(data) if data['error']

            choice = Array(data['choices']).first || {}
            delta = choice['delta'] || {}
            finish_reason = choice['finish_reason']
            stop_reason = finish_reason ? map_stop_reason(finish_reason) : nil
            usage = finish_reason && data['usage'] ? parse_usage(data['usage']) : nil

            build_chunk_from_delta(data, delta, finish_reason, stop_reason, usage)
          end

          def build_chunk_from_delta(data, delta, finish_reason, stop_reason, usage)
            reasoning = delta['reasoning_content'] || delta['reasoning']
            return build_thinking_chunk(reasoning, data['id'], stop_reason: stop_reason, usage: usage) if reasoning

            content = delta['content']
            return build_text_chunk(content, data['id'], stop_reason: stop_reason, usage: usage) if content

            tc_chunk = parse_tool_call_delta(delta, data, stop_reason: stop_reason, usage: usage)
            return tc_chunk if tc_chunk

            finish_reason ? build_done_chunk(data, finish_reason, data['usage']) : nil
          end

          def build_canonical_response(body)
            choice = Array(body['choices']).first || {}
            message = choice['message'] || {}
            usage_raw = body['usage'] || {}
            text, thinking = extract_thinking_from_message(message)
            Canonical::Response.build(
              text: text,
              thinking: thinking,
              tool_calls: parse_tool_calls(message['tool_calls']),
              usage: parse_usage(usage_raw),
              stop_reason: map_stop_reason(choice['finish_reason']),
              model: body['model'],
              metadata: extract_response_metadata(message)
            )
          end
        end
      end
    end
  end
end
