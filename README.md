# lex-llm-openai

LegionIO LLM provider extension for Openai.

This gem lives under `Legion::Extensions::Llm::Openai` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

## What It Provides

- `Legion::Extensions::Llm::Provider` registration as `:openai`
- chat completions through `POST /v1/chat/completions`
- streaming chat completions through the same chat completions endpoint
- model discovery through `GET /v1/models`
- model retrieval through `GET /v1/models/{model}`
- embeddings through `POST /v1/embeddings`
- moderation through `POST /v1/moderations`
- image generation through `POST /v1/images/generations`
- image editing through `POST /v1/images/edits`
- image variation endpoint helper for `POST /v1/images/variations`
- audio transcription through `POST /v1/audio/transcriptions`
- shared OpenAI-compatible request/response mapping via `Legion::Extensions::Llm::Provider::OpenAICompatible`
- shared fleet/default settings via `Legion::Extensions::Llm.provider_settings`

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
  config.default_model = "gpt-5.2"
  config.default_embedding_model = "text-embedding-3-small"
  config.default_moderation_model = "omni-moderation-latest"
  config.default_image_model = "gpt-image-1"
  config.default_transcription_model = "gpt-4o-transcribe"
end
```
