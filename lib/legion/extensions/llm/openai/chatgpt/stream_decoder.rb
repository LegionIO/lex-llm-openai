# frozen_string_literal: true

require 'event_stream_parser'
require_relative 'wire_errors'
require_relative 'translator'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # One state machine feeds both streaming callers and ordinary responses.
          # It never guesses reasoning from visible prose or repairs tool identities.
          class StreamDecoder
            EVENT_GROUPS = {
              'response.created' => :response, 'response.in_progress' => :response, 'response.queued' => :response,
              'response.output_item.added' => :item, 'response.output_item.done' => :item,
              'response.output_text.delta' => :text, 'response.refusal.delta' => :text,
              'response.reasoning_summary_text.delta' => :text, 'response.function_call_arguments.delta' => :arguments,
              'response.completed' => :completion, 'response.done' => :completion,
              'response.failed' => :completion, 'response.incomplete' => :completion, 'error' => :completion,
              'response.output_text.done' => :snapshot, 'response.refusal.done' => :snapshot,
              'response.function_call_arguments.done' => :snapshot, 'response.reasoning_summary_text.done' => :snapshot,
              'response.content_part.added' => :snapshot, 'response.content_part.done' => :snapshot,
              'response.reasoning_summary_part.added' => :snapshot, 'response.reasoning_summary_part.done' => :snapshot
            }.freeze
            ITEM_TYPES = %w[message function_call reasoning].freeze
            TEXT_PART_TYPES = %w[output_text refusal].freeze
            SUMMARY_PART_TYPES = %w[summary_text].freeze

            attr_reader :response

            def initialize(model:, &callback)
              @model = model
              @callback = callback
              @parser = EventStreamParser::Parser.new
              @items = {}
              @request_id = nil
              @sequence = 0
              @terminal = false
              @finished = false
            end

            def feed(bytes:)
              @parser.feed(bytes.encoding == Encoding::BINARY ? bytes : bytes.b) do |event, data|
                next if data.empty?

                if data == '[DONE]'
                  malformed!('Stream ended before response completion') unless @terminal
                  next
                end
                value = parse_event(event: event, data: data)
                malformed!('ChatGPT emitted data after terminal completion') if @terminal
                consume(event: value)
              end
            end

            def finish
              malformed!('ChatGPT stream ended without terminal completion') unless @terminal && @response
              unless @finished
                @finished = true
                emit(type: :done, usage: @response.usage, stop_reason: @response.stop_reason,
                     metadata: @response.metadata)
              end
              @response
            end

            private

            def malformed!(message)
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(message: message, kind: :malformed_output),
                    cause: nil
            end

            def parse_json(data:)
              Legion::JSON.load(data)
            rescue Legion::JSON::ParseError
              malformed!('ChatGPT emitted malformed JSON')
            end

            def parse_event(event:, data:)
              value = parse_json(data: data)
              unless value.is_a?(Hash) && value[:type].is_a?(String)
                malformed!('Stream event must be an object with a type')
              end
              unless event.to_s.empty? || event == 'message' || event == value[:type]
                malformed!('SSE event name contradicts its payload')
              end
              value
            end

            def consume(event:)
              case EVENT_GROUPS[event[:type]]
              when :response then bind_response!(response: event[:response])
              when :item then consume_item(event: event)
              when :text then append_text(event: event)
              when :arguments then append_arguments(event: event)
              when :completion then consume_completion(event: event)
              when :snapshot
                # Final output-item snapshots validate all accumulated content.
                existing_item(event: event)
              else malformed!('Unsupported ChatGPT stream event')
              end
            end

            def consume_item(event:)
              if event[:type] == 'response.output_item.added'
                add_item(index: event[:output_index], item: event[:item])
              else
                reconcile_item(index: event[:output_index], item: event[:item])
              end
            end

            def consume_completion(event:)
              case event[:type]
              when 'response.completed', 'response.done'
                complete(response: event[:response])
              when 'response.incomplete'
                malformed!('ChatGPT returned an incomplete response')
              else
                failure = event[:response].is_a?(Hash) ? event[:response] : event
                Legion::Extensions::Llm::Openai::Chatgpt::WireErrors.raise_response!(status: 200, body: failure)
              end
            end

            def bind_response!(response:)
              validate_response_identity!(response: response)
              malformed!('Response identity changed during streaming') if @request_id && @request_id != response[:id]
              if response[:model] && response[:model] != @model
                malformed!('Response model contradicts the selected model')
              end
              @request_id = response[:id]
            end

            def validate_response_identity!(response:)
              return if response.is_a?(Hash) && response[:id].is_a?(String) && !response[:id].empty?

              malformed!('Missing response identity')
            end

            def add_item(index:, item:)
              validate_item!(index: index, item: item)
              existing = @items[index]
              if existing
                unless existing[:id] == item[:id] && existing[:type] == item[:type]
                  malformed!('Output item identity changed')
                end
                return existing
              end
              register_item(index: index, item: item)
            end

            def register_item(index:, item:)
              malformed!('Duplicate output item identity') if @items.values.any? { |row| row[:id] == item[:id] }
              state = { id: item[:id], type: item[:type], parts: {}, arguments: +'', signature: nil, final: nil }
              @items[index] = state
              initialize_call(index: index, item: item, state: state) if item[:type] == 'function_call'
              state
            end

            def validate_item!(index:, item:)
              malformed!('Invalid output index') unless index.is_a?(Integer) && !index.negative?
              malformed!('Invalid output item') unless item.is_a?(Hash) && item[:id].is_a?(String) && !item[:id].empty?
              malformed!('Unsupported output item type') unless ITEM_TYPES.include?(item[:type])
            end

            def initialize_call(index:, item:, state:)
              validate_call!(item: item)
              state[:call_id] = item[:call_id]
              state[:name] = item[:name]
              emit(type: :tool_call_delta, block_index: index, item_id: item[:id],
                   tool_call: { id: item[:call_id], name: item[:name], arguments: '', index: index })
            end

            def existing_item(event:)
              state = @items[event[:output_index]]
              malformed!('Stream delta has no output item') unless state
              if event[:item_id] && event[:item_id] != state[:id]
                malformed!('Stream delta has contradictory item identity')
              end
              malformed!('Stream delta follows a completed output item') if state[:final]
              state
            end

            def append_text(event:)
              state = existing_item(event: event)
              thinking = event[:type] == 'response.reasoning_summary_text.delta'
              expected = thinking ? 'reasoning' : 'message'
              malformed!('Stream delta has the wrong item type') unless state[:type] == expected
              index = event[thinking ? :summary_index : :content_index]
              append_part(state: state, index: index, delta: event[:delta])
              emit(type: thinking ? :thinking_delta : :text_delta, delta: event[:delta],
                   block_index: event[:output_index], item_id: state[:id], metadata: { content_index: index })
            end

            def append_part(state:, index:, delta:)
              malformed!('Invalid content index') unless index.is_a?(Integer) && !index.negative?
              malformed!('Stream delta must be text') unless delta.is_a?(String)
              state[:parts][index] ||= +''
              state[:parts][index] << delta
            end

            def append_arguments(event:)
              state = existing_item(event: event)
              malformed!('Arguments delta has the wrong item type') unless state[:type] == 'function_call'
              malformed!('Arguments delta must be text') unless event[:delta].is_a?(String)
              state[:arguments] << event[:delta]
              emit(type: :tool_call_delta, block_index: event[:output_index], item_id: state[:id],
                   tool_call: { arguments: event[:delta], index: event[:output_index] })
            end

            def reconcile_item(index:, item:)
              state = add_item(index: index, item: item)
              malformed!('Output item did not complete') if item[:status] && item[:status] != 'completed'
              if state[:final]
                malformed!('Completed output item changed') unless state[:final] == item
                return
              end
              reconcile_item_content(index: index, item: item, state: state)
              state[:final] = item
            end

            def reconcile_item_content(index:, item:, state:)
              case item[:type]
              when 'message'
                malformed!('Output message must have assistant role') unless item[:role] == 'assistant'
                reconcile_parts(index: index, state: state, parts: item[:content], thinking: false)
              when 'reasoning'
                reconcile_reasoning(index: index, item: item, state: state)
              when 'function_call'
                reconcile_call(index: index, item: item, state: state)
              end
            end

            def reconcile_reasoning(index:, item:, state:)
              reconcile_parts(index: index, state: state, parts: item[:summary], thinking: true)
              signature = item[:encrypted_content]
              malformed!('Invalid encrypted reasoning') unless signature.nil? || signature.is_a?(String)
              state[:signature] = signature
              emit(type: :thinking_delta, delta: '', block_index: index, item_id: item[:id], signature: signature,
                   metadata: { reasoning_item: reasoning_item(item: item) })
            end

            def reconcile_call(index:, item:, state:)
              validate_stable_call!(item: item, state: state)
              arguments = completed_arguments(item: item, previous: state[:arguments])
              suffix = arguments.delete_prefix(state[:arguments])
              unless suffix.empty?
                emit(type: :tool_call_delta, block_index: index, item_id: item[:id],
                     tool_call: { arguments: suffix, index: index })
              end
              state[:arguments] = arguments
              state[:parsed_arguments] = parse_arguments(data: arguments)
            end

            def validate_stable_call!(item:, state:)
              validate_call!(item: item)
              return if state[:call_id] == item[:call_id] && state[:name] == item[:name]

              malformed!('Tool call identity changed')
            end

            def completed_arguments(item:, previous:)
              arguments = item[:arguments]
              malformed!('Tool arguments must be a JSON string') unless arguments.is_a?(String)
              malformed!('Tool arguments contradict streamed arguments') unless arguments.start_with?(previous)
              arguments
            end

            def parse_arguments(data:)
              parsed = parse_json(data: data)
              malformed!('Tool arguments must decode to an object') unless parsed.is_a?(Hash)
              parsed
            end

            def reconcile_parts(index:, state:, parts:, thinking:)
              malformed!('Output item is missing content parts') unless parts.is_a?(Array)
              unless (state[:parts].keys - (0...parts.length).to_a).empty?
                malformed!('Final output omitted streamed content')
              end
              parts.each_with_index do |part, part_index|
                reconcile_part(index: index, state: state, part: part, part_index: part_index, thinking: thinking)
              end
            end

            def reconcile_part(index:, state:, part:, part_index:, thinking:)
              text = part_text(part: part, thinking: thinking)
              previous = state[:parts][part_index] || ''
              malformed!('Final output contradicts streamed content') unless text.start_with?(previous)
              suffix = text.delete_prefix(previous)
              unless suffix.empty?
                emit(type: thinking ? :thinking_delta : :text_delta, delta: suffix,
                     block_index: index, item_id: state[:id], metadata: { content_index: part_index })
              end
              state[:parts][part_index] = text
            end

            def part_text(part:, thinking:)
              allowed = thinking ? SUMMARY_PART_TYPES : TEXT_PART_TYPES
              malformed!('Unsupported output content part') unless part.is_a?(Hash) && allowed.include?(part[:type])
              text = part[:type] == 'refusal' ? part[:refusal] : part[:text]
              malformed!('Output content must be text') unless text.is_a?(String)
              text
            end

            def validate_call!(item:)
              unless valid_call_identifier?(value: item[:call_id]) && valid_call_identifier?(value: item[:name])
                malformed!('ChatGPT returned an invalid tool identity')
              end
              return unless @items.values.any? { |state| state[:id] != item[:id] && state[:call_id] == item[:call_id] }

              malformed!('ChatGPT returned duplicate tool call identities')
            end

            def valid_call_identifier?(value:)
              value.is_a?(String) && Legion::Extensions::Llm::Openai::Chatgpt::Translator::IDENTIFIER.match?(value)
            end

            def complete(response:)
              bind_response!(response: response)
              output = completed_output(response: response)
              output.each_with_index { |item, index| reconcile_item(index: index, item: item) }
              usage = parse_usage(value: response[:usage])
              @response = build_response(output: output, usage: usage)
              @terminal = true
              emit(type: :usage, usage: usage) if usage
            end

            def completed_output(response:)
              malformed!('Terminal event did not confirm completion') unless response[:status] == 'completed'
              malformed!('Terminal completion contained an error') unless response[:error].nil?
              output = response[:output]
              malformed!('Terminal event omitted its output') unless output.is_a?(Array)
              unless (@items.keys - (0...output.length).to_a).empty?
                malformed!('Terminal event omitted streamed output items')
              end
              output
            end

            def build_response(output:, usage:)
              reasoning = response_reasoning_items(output: output)
              text = response_text_parts(output: output)
              calls = build_calls(output: output)
              Legion::Extensions::Llm::Canonical::Response.build(
                text: text.map { |part| part[:type] == 'refusal' ? part[:refusal] : part[:text] }.join,
                thinking: build_thinking(reasoning: reasoning), tool_calls: calls, usage: usage,
                stop_reason: response_stop_reason(text: text, calls: calls), model: @model,
                metadata: { response_id: @request_id, reasoning_items: reasoning }
              )
            end

            def response_reasoning_items(output:)
              output.select { |item| item[:type] == 'reasoning' }.map { |item| reasoning_item(item: item) }
            end

            def response_text_parts(output:)
              output.select { |item| item[:type] == 'message' }.flat_map { |item| item[:content] }
            end

            def build_calls(output:)
              output.each_with_index.filter_map do |item, index|
                next unless item[:type] == 'function_call'

                Legion::Extensions::Llm::Canonical::ToolCall.build(
                  id: item[:call_id], name: item[:name], arguments: @items.fetch(index)[:parsed_arguments],
                  metadata: { item_id: item[:id] }
                )
              end
            end

            def response_stop_reason(text:, calls:)
              return :content_filter if text.any? { |part| part[:type] == 'refusal' }

              calls.empty? ? :end_turn : :tool_use
            end

            def reasoning_item(item:)
              item.slice(:type, :id, :summary, :encrypted_content)
            end

            def build_thinking(reasoning:)
              return nil if reasoning.empty?

              Legion::Extensions::Llm::Canonical::Thinking.build(
                content: reasoning.flat_map { |item| item[:summary].map { |part| part[:text] } }.join,
                signature: reasoning.length == 1 ? reasoning.first[:encrypted_content] : nil,
                metadata: { reasoning_items: reasoning }
              )
            end

            def parse_usage(value:)
              return nil if value.nil?

              malformed!('Malformed subscription usage') unless value.is_a?(Hash)
              fields = usage_fields(value: value)
              malformed!('Invalid subscription token count') unless fields.values.all? do |count|
                count.nil? || (count.is_a?(Integer) && !count.negative?)
              end
              Legion::Extensions::Llm::Canonical::Usage.build(**fields)
            end

            def usage_fields(value:)
              input_details = value[:input_tokens_details] || {}
              output_details = value[:output_tokens_details] || {}
              unless input_details.is_a?(Hash) && output_details.is_a?(Hash)
                malformed!('Malformed subscription usage details')
              end
              { input_tokens: value[:input_tokens], output_tokens: value[:output_tokens],
                cache_read_tokens: input_details[:cached_tokens], thinking_tokens: output_details[:reasoning_tokens] }
            end

            def emit(type:, metadata: {}, **fields)
              chunk = Legion::Extensions::Llm::Canonical::Chunk.build(
                type: type, request_id: @request_id, index: @sequence, metadata: metadata.merge(model: @model), **fields
              )
              @sequence += 1
              @callback&.call(chunk)
            end
          end
        end
      end
    end
  end
end
