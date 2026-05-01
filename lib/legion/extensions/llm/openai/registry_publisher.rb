# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Openai
        # Best-effort publisher for OpenAI provider availability events.
        class RegistryPublisher
          include Legion::Logging::Helper

          APP_ID = 'lex-llm-openai'

          def initialize(builder: RegistryEventBuilder.new)
            @builder = builder
          end

          def publish_models_async(models, readiness:)
            log.info("Publishing #{Array(models).size} model(s) to llm.registry")
            schedule do
              Array(models).each do |model|
                publish_event(@builder.model_available(model, readiness:))
              end
            end
          end

          private

          def schedule(&)
            return false unless publishing_available?

            Thread.new do
              Thread.current.abort_on_exception = false
              yield
            rescue StandardError => e
              handle_exception(e, level: :debug, handled: true, operation: 'schedule')
            end
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'schedule')
            false
          end

          def publish_event(event)
            return false unless publishing_available?

            message_class.new(event:, app_id: APP_ID).publish(spool: false)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true,
                                operation: 'publish_event')
            false
          end

          def publishing_available?
            return false unless registry_event_available?
            return false unless transport_message_available?
            return true unless defined?(::Legion::Transport::Connection)
            return true unless ::Legion::Transport::Connection.respond_to?(:session_open?)

            ::Legion::Transport::Connection.session_open?
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true,
                                operation: 'publishing_available?')
            false
          end

          def registry_event_available?
            defined?(::Legion::Extensions::Llm::Routing::RegistryEvent)
          end

          def transport_message_available?
            return true if message_class_defined?
            return false unless defined?(::Legion::Transport::Message) && defined?(::Legion::Transport::Exchange)

            require 'legion/extensions/llm/openai/transport/messages/registry_event'
            message_class_defined?
          rescue LoadError => e
            handle_exception(e, level: :debug, handled: true,
                                operation: 'transport_message_available?')
            false
          end

          def message_class_defined?
            defined?(::Legion::Extensions::Llm::Openai::Transport::Messages::RegistryEvent)
          end

          def message_class
            ::Legion::Extensions::Llm::Openai::Transport::Messages::RegistryEvent
          end
        end
      end
    end
  end
end
