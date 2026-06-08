# lex-llm-openai

LegionIO LLM provider extension for OpenAI.

This gem provides the `:openai` provider family implementation, enabling LegionIO to route chat, streaming, embedding, moderation, image, and audio requests to OpenAI-compatible APIs through the shared `lex-llm` provider contract.

**Namespace:** `Legion::Extensions::Llm::Openai`
**Version:** 0.3.11
**Load:** `require 'legion/extensions/llm/openai'`

## Quick Start

```ruby
require 'legion/extensions/llm/openai'

# Configure via the shared LLM configuration API
Legion::Extensions::Llm.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
  config.default_model = "gpt-5.5"
end

# Use through the standard provider interface
provider = Legion::Extensions::Llm::Openai::Provider.new
provider.chat(model: "gpt-5.5", messages: [{ role: "user", content: "Hello" }])
```

## What It Provides

| Capability | Endpoint | Notes |
|---|---|---|
| Chat completions | `POST /v1/chat/completions` | Includes function calling, vision, structured output |
| Streaming chat | Same endpoint, `stream: true` | Token usage reported via `stream_usage_supported?` |
| Model listing | `GET /v1/models` | Enriched with static capability map; publishes registry events |
| Model retrieval | `GET /v1/models/{model}` | |
| Embeddings | `POST /v1/embeddings` | |
| Moderation | `POST /v1/moderations` | |
| Image generation | `POST /v1/images/generations` | |
| Image editing | `POST /v1/images/edits` | |
| Image variation | `POST /v1/images/variations` | |
| Audio transcription | `POST /v1/audio/transcriptions` | Whisper, gpt-4o-transcribe |

## Architecture

```
Legion::Extensions::Llm::Openai
|-- Openai                              # Root module — settings, discovery, auto-registration
|   |-- default_settings                # Provider family defaults (endpoint, models, fleet)
|   |-- discover_instances              # Credential scanning across env, Codex, Claude, settings
|   |-- normalize_instance_config       # Normalizes generic keys to canonical OpenAI keys
|   `-- sanitize_instance_config        # Strips temporary credential fields
|
|-- Provider                            # OpenAI provider implementation
|   |-- Capabilities                    # Model family predicates (chat?, streaming?, vision?, etc.)
|   |-- CAPABILITY_MAP                  # Static capability matrix for 14 known model families
|   |-- list_models                     # Enriches raw API response with capability metadata
|   |-- retrieve_model                  # Fetches single model detail
|   |-- chat_url, models_url, etc.      # Endpoint builders
|   `-- maybe_normalize_temperature     # Adjusts temperature for o*/gpt-5 reasoning models
|
|-- Actor::FleetWorker                  # Subscription actor for fleet request consumption
|   |-- enabled?                        # Checks if any instance has respond_to_requests: true
|   `-- Delegates to lex-llm ProviderResponder
|
|-- Actor::DiscoveryRefresh             # Periodic actor that refreshes the model discovery cache
|   |-- time                            # Reads discovery_interval from settings (default 1800s)
|   `-- Calls Legion::LLM::Discovery.refresh_discovered_models!
|
`-- Runners::FleetWorker                # Execution entrypoint for fleet requests
    `-- handle_fleet_request            # Routes to lex-llm ProviderResponder.call
```

### Design Boundaries

- **Response normalization, request payload mapping** lives in `Lex-llm::Provider::OpenAICompatible` (mixed in)
- **Fleet responder logic** (ack/reject, response publication) lives in `Lex-llm::Fleet::ProviderResponder`
- **Registry event publishing** is delegated to `Lex-llm::RegistryPublisher`
- This extension depends **only** on `lex-llm` at runtime; it does not depend on `legion-llm`

## Instance Discovery

`Openai.discover_instances` scans 7 credential sources, deduplicates by key, and injects `default_model`:

| Priority | Source | Key |
|---|---|---|
| 1 | `OPENAI_API_KEY` environment variable | `:env` |
| 2 | `CODEX_API_KEY` environment variable | `:codex_env` |
| 3 | Codex bearer token (`~/.codex/auth.json`) | `:codex` |
| 4 | Codex OpenAI key (`~/.codex/auth.json`) | `:codex_key` |
| 5 | Claude config (`openaiApiKey`) | `:claude` |
| 6 | Extension settings (`extensions.llm.openai`) | `:settings` |
| 7 | Named instances in extension settings | Named keys |

## Configuration

### Via Legion Settings (YAML)

```yaml
extensions:
  llm:
    openai:
      api_key: "sk-..."
      default_model: "gpt-5.5"
      endpoint: "https://api.openai.com"
      discovery_interval: 1800    # Seconds between model list refresh (used by DiscoveryRefresh actor)
      instances:
        primary:
          openai_api_key: "sk-..."
          openai_api_base: "https://api.openai.com"
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
              - image
```

### Via Ruby Configuration API

```ruby
Legion::Extensions::Llm.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
  config.openai_api_base = nil                     # defaults to https://api.openai.com
  config.openai_organization_id = nil              # optional OpenAI-Organization header
  config.openai_project_id = nil                   # optional OpenAI-Project header
  config.openai_use_system_role = true             # include system messages in requests
  config.default_model = "gpt-5.5"
  config.default_embedding_model = "text-embedding-3-small"
  config.default_moderation_model = "omni-moderation-latest"
  config.default_image_model = "gpt-image-1"
  config.default_transcription_model = "gpt-4o-transcribe"
end
```

### Default Settings

```ruby
Legion::Extensions::Llm::Openai.default_settings
# {
#   provider_family: :openai,
#   instances: {
#     default: {
#       endpoint: "https://api.openai.com",
#       default_model: "gpt-5.5",
#       tier: :frontier,
#       transport: :http,
#       credentials: {
#         api_key: "env://OPENAI_API_KEY",
#         organization_id: nil,
#         project_id: nil
#       },
#       usage: {
#         inference: true,
#         embedding: true,
#         moderation: true,
#         image: true,
#         audio: true
#       },
#       limits: { concurrency: 4 },
#       fleet: {
#         enabled: false,
#         respond_to_requests: false,
#         capabilities: [:chat, :stream_chat, :embed, :image],
#         lanes: [],
#         concurrency: 4,
#         queue_suffix: nil
#       }
#     }
#   }
# }
```

## Model Capability Map

The provider maintains a static `CAPABILITY_MAP` covering 14 OpenAI model families. Each entry declares capabilities, input/output modalities, and context window size.

| Prefix | Capabilities | Input | Output | Context |
|---|---|---|---|---|
| `gpt-4o` | completion, streaming, function_calling, vision, structured_output | text, image, audio | text | 128K |
| `gpt-4.1` | completion, streaming, function_calling, vision, structured_output | text, image | text | 1M |
| `gpt-4` | completion, streaming, function_calling, vision | text, image | text | 128K |
| `gpt-5` | completion, streaming, function_calling, vision, structured_output, reasoning | text, image | text | 1M |
| `o4` | completion, streaming, function_calling, vision, reasoning | text, image | text | 200K |
| `o3` | completion, streaming, function_calling, vision, reasoning | text, image | text | 200K |
| `o1` | completion, streaming, function_calling, vision, reasoning | text, image | text | 200K |
| `text-embedding-*` | embedding | text | embeddings | 8K |
| `omni-moderation` | moderation | text, image | moderation | - |
| `text-moderation` | moderation | text | moderation | - |
| `gpt-image` | image_generation | text, image | image | - |
| `dall-e` | image_generation | text | image | - |
| `whisper` | audio_transcription | audio | text | - |
| `tts` | audio_generation | text | audio | - |

Unknown models default to `{ capabilities: [:completion, :streaming], modalities: { input: ["text"], output: ["text"] } }`.

## Capability Predicates

`Provider::Capabilities` provides module functions for model routing decisions:

| Method | Matches |
|---|---|
| `chat?(model)` | Any model that is not embedding, moderation, image, audio, tts, realtime, or sora |
| `streaming?(model)` | Same as `chat?` |
| `functions?(model)` | Models starting with `gpt` or `o\d` |
| `vision?(model)` | Models starting with `gpt`, `o\d`, or `omni-moderation` |
| `embeddings?(model)` | Models starting with `text-embedding-` |
| `moderation?(model)` | Models containing `moderation` |
| `images?(model)` | Models starting with `gpt-image` or `dall-e` |
| `audio_transcription?(model)` | Models matching `gpt-4o.*transcribe` or `whisper` |

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests via the shared `ProviderResponder`. The fleet actor starts automatically when any instance has `respond_to_requests: true`.

### Fleet YAML Configuration

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

### Fleet Components

| Class | Role |
|---|---|
| `Actor::FleetWorker` | Subscription actor; checks `enabled?` against discovered instances |
| `Runners::FleetWorker.handle_fleet_request` | Execution entrypoint; delegates to `ProviderResponder.call` |

## Observability

All classes include `Legion::Logging::Helper`:

- **Structured error handling:** Every `rescue` calls `handle_exception` with operation context
- **Debug-level request telemetry:** Model listing, retrieval, fleet dispatch, discovery refresh
- **Info-level action logging:** Registry publishing, instance discovery results
- **Automatic segment derivation:** Log lines tagged with provider family and component type

## Dependencies

| Gem | Purpose |
|-----|---------|
| `lex-llm` (>= 0.4.3) | Provider contract, OpenAICompatible mixin, fleet responder, registry publisher |
| `legion-transport` (>= 1.4.14) | AMQP subscriptions and replies |
| `legion-json` (>= 1.2.1) | JSON serialization |
| `legion-logging` (>= 1.3.2) | Structured logging |
| `legion-settings` (>= 1.3.14) | Configuration management |

## Key Files

| File | Purpose |
|------|---------|
| `lib/legion/extensions/llm/openai.rb` | Root module, settings, instance discovery, auto-registration |
| `lib/legion/extensions/llm/openai/provider.rb` | Provider implementation, capability map, API methods |
| `lib/legion/extensions/llm/openai/actors/discovery_refresh.rb` | Periodic model cache refresh actor |
| `lib/legion/extensions/llm/openai/actors/fleet_worker.rb` | Fleet request subscription actor |
| `lib/legion/extensions/llm/openai/runners/fleet_worker.rb` | Fleet request execution runner |
| `lib/legion/extensions/llm/openai/version.rb` | Version constant |

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

MIT
