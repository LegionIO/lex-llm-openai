# lex-llm-openai

LegionIO LLM provider extension for OpenAI.

This gem lives under `Legion::Extensions::Llm::Openai` and depends on `lex-llm >= 0.4.3` for shared provider-neutral routing, response normalization, fleet envelopes, fleet responder execution, and schema primitives.

Load it with `require 'legion/extensions/llm/openai'`.

## What It Provides

- `Legion::Extensions::Llm::Provider` registration as `:openai`
- Chat completions via `POST /v1/chat/completions`
- Streaming chat completions (same endpoint, `stream: true`)
- Model discovery via `GET /v1/models`
- Model retrieval via `GET /v1/models/{model}`
- Embeddings via `POST /v1/embeddings`
- Moderation via `POST /v1/moderations`
- Image generation via `POST /v1/images/generations`
- Image editing via `POST /v1/images/edits`
- Image variation via `POST /v1/images/variations`
- Audio transcription via `POST /v1/audio/transcriptions`
- Streaming token usage reporting (`stream_usage_supported?`)
- Shared OpenAI-compatible request/response mapping via `Legion::Extensions::Llm::Provider::OpenAICompatible`
- Normalized chat, embedding, moderation, image, and audio capability mapping for discovered models
- Shared fleet/default settings via `Legion::Extensions::Llm.provider_settings`
- Best-effort `llm.registry` availability event publishing for discovered models

## Architecture

```
Legion::Extensions::Llm::Openai
├── Provider                              # OpenAI provider implementation (chat, models, embeddings, etc.)
│   └── Capabilities                      # Model family capability predicates
├── RegistryPublisher                     # Async llm.registry event publisher
├── RegistryEventBuilder                  # Sanitized registry event envelope builder
└── Transport
    ├── Exchanges::LlmRegistry            # Topic exchange for llm.registry
    └── Messages::RegistryEvent           # AMQP message for registry events
```

## Observability

All classes include `Legion::Logging::Helper` (when available) providing:

- Structured `handle_exception` calls on every rescue block
- Info-level action logging for provider registration, model listing, model retrieval, and registry publishing
- Automatic log segment derivation and component type tagging

## Defaults

```ruby
Legion::Extensions::Llm::Openai.default_settings
# {
#   provider_family: :openai,
#   instances: {
#     default: {
#       endpoint: "https://api.openai.com",
#       tier: :frontier,
#       transport: :http,
#       credentials: { api_key: "env://OPENAI_API_KEY" },
#       usage: { inference: true, embedding: true, moderation: true, image: true, audio: true },
#       limits: { concurrency: 4 }
#     }
#   }
# }
```

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
  config.openai_api_base = nil                          # defaults to https://api.openai.com
  config.openai_organization_id = nil                   # optional OpenAI-Organization header
  config.openai_project_id = nil                        # optional OpenAI-Project header
  config.default_model = "gpt-5.2"
  config.default_embedding_model = "text-embedding-3-small"
  config.default_moderation_model = "omni-moderation-latest"
  config.default_image_model = "gpt-image-1"
  config.default_transcription_model = "gpt-4o-transcribe"
end
```

## Dependencies

| Gem | Purpose |
|-----|---------|
| `lex-llm` (>= 0.4.3) | Shared provider contract, response normalization, fleet settings, routing, and fleet responder execution |
| `legion-transport` (>= 1.4.14) | AMQP subscriptions and replies |
| `legion-json` (>= 1.2.1) | JSON serialization |
| `legion-logging` (>= 1.3.2) | Structured logging via Helper |
| `legion-settings` (>= 1.3.14) | Configuration management |

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one configured instance enables `respond_to_requests`.

```yaml
extensions:
  llm:
    openai:
      instances:
        local:
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
              - image
```

## Development

```bash
bundle install
bundle exec rspec --format progress   # all pass
bundle exec rubocop -A                # auto-fix
bundle exec rubocop                   # lint check (0 offenses)
```

## License

MIT
