# frozen_string_literal: true

require 'legion/extensions/llm'
require_relative 'error'

module Legion
  module Extensions
    module Llm
      module Openai
        module Chatgpt
          # The subscription Responses dialect, directly from Canonical state.
          class Translator
            UNSUPPORTED_PARAMS = %i[max_tokens temperature top_p top_k stop_sequences seed frequency_penalty
                                    presence_penalty response_format].freeze
            IDENTIFIER = /\A[a-zA-Z0-9_-]{1,64}\z/
            REQUEST_CONTROLS = %i[params schema thinking tool_prefs].freeze

            # Named controls remain required even when nil, as in the provider API.
            def render(messages:, model:, tools:, **controls)
              validate_render_controls!(controls: controls)
              validate_model!(model: model)
              validate_controls!(params: controls[:params], schema: controls[:schema], thinking: controls[:thinking])
              render_payload(messages: messages, model: model, tools: tools, controls: controls)
            end

            private

            def invalid!(message)
              raise Legion::Extensions::Llm::Openai::Chatgpt::Error.new(message: message, kind: :invalid_request),
                    cause: nil
            end

            def validate_render_controls!(controls:)
              missing = REQUEST_CONTROLS - controls.keys
              raise ArgumentError, "missing keywords: #{missing.join(', ')}" unless missing.empty?

              unknown = controls.keys - REQUEST_CONTROLS
              raise ArgumentError, "unknown keywords: #{unknown.join(', ')}" unless unknown.empty?
            end

            def validate_model!(model:)
              return if model.is_a?(String) && !model.empty? && !model.match?(/[\r\n;]/)

              invalid!('A selected model ID is required')
            end

            def render_payload(messages:, model:, tools:, controls:)
              payload = { model: model, input: render_history(messages: messages), instructions: '',
                          stream: true, store: false, include: ['reasoning.encrypted_content'] }
              payload[:tools] = render_tools(tools: tools) unless tools.nil? || tools.empty?
              apply_tool_preferences!(payload: payload, preferences: controls[:tool_prefs])
              thinking = controls[:thinking]
              payload[:reasoning] = render_thinking(thinking: thinking) if thinking
              payload
            end

            def validate_controls!(params:, schema:, thinking:)
              validate_control_types!(params: params, thinking: thinking)
              invalid!('ChatGPT subscriptions do not support an authoritative output schema') unless schema.nil?
              validate_params!(params: params) if params
              validate_thinking!(thinking: thinking) if thinking
            end

            def validate_control_types!(params:, thinking:)
              if params && !params.is_a?(Legion::Extensions::Llm::Canonical::Params)
                raise ArgumentError, 'params must be Canonical::Params'
              end
              return unless thinking && !thinking.is_a?(Legion::Extensions::Llm::Canonical::Thinking::Config)

              raise ArgumentError, 'thinking must be Canonical::Thinking::Config'
            end

            def validate_params!(params:)
              supplied = UNSUPPORTED_PARAMS.reject { |key| params.public_send(key).nil? }
              invalid!("ChatGPT subscriptions do not support: #{supplied.join(', ')}") unless supplied.empty?
              return if params.metadata.empty?

              invalid!('ChatGPT subscriptions do not support additional request parameters')
            end

            def validate_thinking!(thinking:)
              invalid!('ChatGPT subscriptions do not support an authoritative thinking budget') if thinking.budget
              unless thinking.metadata.empty?
                invalid!('ChatGPT subscriptions do not support additional thinking controls')
              end
              return if thinking.enabled
              return unless disabled_reasoning_controls?(thinking: thinking)

              invalid!('Disabled thinking conflicts with requested reasoning controls')
            end

            def disabled_reasoning_controls?(thinking:)
              (thinking.effort && thinking.effort != 'none') || (thinking.summary && thinking.summary != :none)
            end

            def render_thinking(thinking:)
              return { effort: 'none' } unless thinking.enabled

              result = {}
              result[:effort] = thinking.effort if thinking.effort
              result[:summary] = thinking.summary.to_s if thinking.summary && thinking.summary != :none
              result
            end

            def render_tools(tools:)
              tools.map do |key, tool|
                validate_tool!(key: key, tool: tool)
                strict = tool_strict(metadata: tool.metadata.transform_keys(&:to_sym))
                { type: 'function', name: tool.name, description: tool.description, parameters: tool.parameters,
                  strict: strict }.compact
              end
            end

            def validate_tool!(key:, tool:)
              unless tool.is_a?(Legion::Extensions::Llm::Canonical::ToolDefinition)
                raise ArgumentError, 'tools must contain Canonical::ToolDefinition objects'
              end

              invalid!('Tool registry key must equal its authoritative name') unless key.to_s == tool.name
              return if IDENTIFIER.match?(tool.name)

              invalid!('Tool name is not representable by the subscription protocol')
            end

            def tool_strict(metadata:)
              invalid!('Unsupported tool definition controls') unless (metadata.keys - [:strict]).empty?
              strict = metadata[:strict]
              invalid!('Tool strict must be boolean') unless strict.nil? || [true, false].include?(strict)
              strict
            end

            def normalize_tool_preferences(preferences:)
              return if preferences.nil?
              raise ArgumentError, 'tool_prefs must be a Hash' unless preferences.is_a?(Hash)
              return if preferences.empty?

              preferences = preferences.transform_keys(&:to_sym)
              invalid!('Unsupported tool preference') unless (preferences.keys - %i[choice parallel_tool_calls]).empty?
              preferences
            end

            def apply_tool_preferences!(payload:, preferences:)
              preferences = normalize_tool_preferences(preferences: preferences)
              return unless preferences

              names = Array(payload[:tools]).map { |tool| tool[:name] }
              if preferences[:choice]
                payload[:tool_choice] = render_tool_choice(choice: preferences[:choice], names: names)
              end
              apply_parallel_preference!(payload: payload, preferences: preferences, names: names)
            end

            def render_tool_choice(choice:, names:)
              unless choice.is_a?(String) || choice.is_a?(Symbol)
                invalid!('Tool choice must be a name or a supported mode')
              end
              choice = choice.to_s
              if %w[auto none required].include?(choice)
                invalid!('Required tool choice needs tool definitions') if choice == 'required' && names.empty?
                return choice
              end
              invalid!('Tool choice does not name a supplied tool') unless names.include?(choice)
              { type: 'function', name: choice }
            end

            def apply_parallel_preference!(payload:, preferences:, names:)
              return unless preferences.key?(:parallel_tool_calls)

              parallel = preferences[:parallel_tool_calls]
              unless [true, false].include?(parallel) && !names.empty?
                invalid!('parallel_tool_calls must be boolean and needs tool definitions')
              end
              payload[:parallel_tool_calls] = parallel
            end

            def render_history(messages:)
              history = { pending: {}, seen: {} }
              items = Array(messages).flat_map do |message|
                validate_message!(message: message, pending: history[:pending])
                render_message(message: message, history: history)
              end
              invalid!('Tool calls without results cannot be replayed') unless history[:pending].empty?
              invalid!('An input conversation is required') if items.empty?
              items
            end

            def validate_message!(message:, pending:)
              unless message.is_a?(Legion::Extensions::Llm::Canonical::Message)
                raise ArgumentError, 'messages must contain Canonical::Message objects'
              end

              invalid!('Prompt cache breakpoints are unsupported') if message.cache_control
              return unless pending.any? && message.role != :tool && !tool_result_message?(message: message)

              invalid!('A tool call must receive its result before another conversation turn')
            end

            def tool_result_message?(message:)
              block = Array(message.content).first
              message.role == :user && content_block?(block: block, type: :tool_result)
            end

            def content_block?(block:, type:)
              block.is_a?(Legion::Extensions::Llm::Canonical::ContentBlock) && block.type == type
            end

            def render_message(message:, history:)
              return render_tool_message(message: message, pending: history[:pending]) if message.role == :tool

              if message.role != :assistant && message.tool_calls&.any?
                invalid!('Only assistant messages may contain tool calls')
              end
              render_message_content(message: message, history: history)
            end

            def render_message_content(message:, history:)
              output = { items: render_reasoning(message: message), content: [] }
              Array(message.content).each do |block|
                append_content(block: block, role: message.role, output: output, history: history)
              end
              flush_content(output: output, role: message.role)
              append_message_calls(message: message, items: output[:items], history: history)
              output[:items]
            end

            def render_tool_message(message:, pending:)
              invalid!('Tool result messages cannot contain tool calls') if message.tool_calls&.any?
              [render_result(id: message.tool_call_id, content: message.content, pending: pending)]
            end

            def append_message_calls(message:, items:, history:)
              Array(message.tool_calls).each do |call|
                items << render_call(id: call.id, name: call.name, arguments: call.arguments,
                                     metadata: call.metadata, history: history)
              end
            end

            def flush_content(output:, role:)
              return if output[:content].empty?

              output[:items] << { type: 'message', role: role == :system ? 'developer' : role.to_s,
                                  content: output[:content] }
              output[:content] = []
            end

            def append_content(block:, role:, output:, history:)
              if role == :user && history[:pending].any? && !content_block?(block: block, type: :tool_result)
                invalid!('All pending tool calls need results before new user content')
              end
              if block.is_a?(String)
                output[:content] << render_text(text: block, role: role)
                return
              end
              unless block.is_a?(Legion::Extensions::Llm::Canonical::ContentBlock)
                raise ArgumentError, 'message content must be Canonical::ContentBlock'
              end

              invalid!('Prompt cache breakpoints are unsupported') if block.cache_control
              append_typed_content(block: block, role: role, output: output, history: history)
            end

            def append_typed_content(block:, role:, output:, history:)
              case block.type
              when :text
                output[:content] << render_text(text: block.text, role: role)
              when :image
                invalid!('Images are supported only in user input') unless role == :user
                output[:content] << render_image(block: block)
              when :tool_use
                append_tool_call(block: block, role: role, output: output, history: history)
              when :tool_result
                append_tool_result(block: block, role: role, output: output, history: history)
              when :thinking
                validate_thinking_content!(items: output[:items])
              else
                invalid!('Unsupported subscription input content type')
              end
            end

            def validate_thinking_content!(items:)
              return if items.any? { |item| item[:type] == 'reasoning' }

              invalid!('Thinking history requires opaque reasoning_items metadata')
            end

            def render_text(text:, role:)
              invalid!('Text content must be a String') unless text.is_a?(String)
              { type: role == :assistant ? 'output_text' : 'input_text', text: text }
            end

            def append_tool_call(block:, role:, output:, history:)
              invalid!('Tool calls require an assistant role') unless role == :assistant
              flush_content(output: output, role: role)
              output[:items] << render_call(id: block.id, name: block.name, arguments: block.input,
                                            metadata: block.metadata, history: history)
            end

            def append_tool_result(block:, role:, output:, history:)
              invalid!('Tool results require a user or tool role') unless role == :user
              invalid!('Subscription tool outputs cannot represent an explicit error flag') if block.is_error
              flush_content(output: output, role: role)
              output[:items] << render_result(id: block.tool_use_id, content: block.text, pending: history[:pending])
            end

            def render_image(block:)
              invalid!('Image data must be a nonempty String') unless block.data.is_a?(String) && !block.data.empty?
              url = image_url(block: block)
              detail = block.detail&.to_s
              invalid!('Unsupported image detail') if detail && !%w[auto low high original].include?(detail)
              { type: 'input_image', image_url: url, detail: detail }.compact
            end

            def image_url(block:)
              case block.source_type&.to_sym
              when :base64
                unless %w[image/png image/jpeg image/webp image/gif].include?(block.media_type)
                  invalid!('Unsupported image media type')
                end
                "data:#{block.media_type};base64,#{block.data}"
              when :url
                unless block.data.start_with?('https://', 'data:image/')
                  invalid!('Image URL must use HTTPS or a data image URI')
                end
                block.data
              else
                invalid!('Unsupported image source type')
              end
            end

            def render_call(id:, name:, arguments:, metadata:, history:)
              register_call!(id: id, name: name, arguments: arguments, history: history)
              item = { type: 'function_call', call_id: id, name: name, arguments: Legion::JSON.dump(arguments) }
              if metadata[:item_id]
                unless metadata[:item_id].is_a?(String) && !metadata[:item_id].empty?
                  invalid!('Tool item identity must be a nonempty String')
                end
                item[:id] = metadata[:item_id]
              end
              item
            end

            def register_call!(id:, name:, arguments:, history:)
              validate_call_arguments!(id: id, name: name, arguments: arguments)
              invalid!('Duplicate tool call identity') if history[:seen][id]
              history[:seen][id] = true
              history[:pending][id] = true
            end

            def validate_call_arguments!(id:, name:, arguments:)
              invalid!('Tool call identity is not representable') unless id.is_a?(String) && IDENTIFIER.match?(id)
              invalid!('Tool call name is not representable') unless name.is_a?(String) && IDENTIFIER.match?(name)
              invalid!('Tool call arguments must be an object') unless arguments.is_a?(Hash)
            end

            def render_result(id:, content:, pending:)
              invalid!('Tool result has no matching unresolved call') unless pending.delete(id)
              output = case content
                       when String then content
                       when Legion::Extensions::Llm::Canonical::ContentBlock then result_text(block: content)
                       when Array then content.map { |block| result_text(block: block) }.join
                       else invalid!('Tool result content must be text')
                       end
              { type: 'function_call_output', call_id: id, output: output }
            end

            def result_text(block:)
              unless content_block?(block: block, type: :text) && block.text.is_a?(String)
                invalid!('Only text tool results are supported')
              end
              block.text
            end

            def render_reasoning(message:)
              rows = reasoning_rows(message: message)
              return [] if rows.nil?

              unless message.role == :assistant && rows.is_a?(Array)
                invalid!('Reasoning replay requires assistant reasoning items')
              end
              rows.map do |row|
                validate_reasoning_item!(row: row)
                row.slice(:type, :id, :summary, :encrypted_content)
              end
            end

            def reasoning_rows(message:)
              blocks = Array(message.content).select { |block| content_block?(block: block, type: :thinking) }
              rows = message.metadata[:reasoning_items]
              rows ||= blocks.flat_map { |block| Array(block.metadata[:reasoning_items]) } unless blocks.empty?
              rows
            end

            def validate_reasoning_item!(row:)
              unless row.is_a?(Hash) && row[:type] == 'reasoning' && row[:id].is_a?(String)
                invalid!('Malformed opaque reasoning history')
              end
              unless row[:encrypted_content].is_a?(String) && !row[:encrypted_content].empty? &&
                     row[:summary].is_a?(Array)
                invalid!('Malformed opaque reasoning history')
              end
              validate_reasoning_summary!(summary: row[:summary])
            end

            def validate_reasoning_summary!(summary:)
              return if summary.all? do |part|
                part.is_a?(Hash) && part[:type] == 'summary_text' && part[:text].is_a?(String)
              end

              invalid!('Malformed reasoning summary history')
            end
          end
        end
      end
    end
  end
end
