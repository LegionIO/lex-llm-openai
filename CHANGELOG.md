# Changelog

## 0.3.5 - 2026-05-06

- Advertise OpenAI moderation and audio usage in the default provider instance settings.
- Refresh README architecture and verification guidance for the shared `lex-llm` registry and fleet responder boundary.

## 0.3.4 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.

## 0.3.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

## 0.3.2 - 2026-05-06

- Add provider contract specs for the shared keyword-only `lex-llm` provider API.
- Move OpenAI defaults back to `Legion::Extensions::Llm.provider_settings` with credentials and instance-level fleet responder settings.
- Remove `gateways` discovery; OpenAI-compatible targets are now named provider instances.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.3.1 - 2026-05-03

- Normalize generic settings keys to OpenAI provider config keys during extension and gateway instance discovery.

## 0.3.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## [0.2.0] - 2026-04-30
- **BREAKING**: Adopt base contract from lex-llm 0.1.9; require `lex-llm >= 0.1.9`
- Replace `provider_settings`-based `default_settings` with flat provider defaults (enabled, default_model, api_key, etc.)
- Remove deprecated `Provider.register` call; configuration options are now registered at class-load time
- Delete local `RegistryPublisher` and `RegistryEventBuilder`; use parameterized base classes from lex-llm
- Delete local `transport/` directory (exchanges, messages); use shared transport from lex-llm
- Add static `CAPABILITY_MAP` for known OpenAI model families; `list_models` now returns `Model::Info` structs directly
- `list_models` no longer delegates to `parse_list_models_response`; builds `Model::Info` via the static capability map

## [0.1.8] - 2026-04-30
- Add Legion::Logging::Helper to all modules and classes for structured observability
- Replace bare rescue blocks with handle_exception for unified error telemetry
- Add info-level action logging for provider registration, model listing, model retrieval, and registry publishing
- Remove manual log_publish_failure helper in favor of handle_exception
- Update README to reflect current capabilities and architecture

## [0.1.7] - 2026-04-30
- Enable stream_usage_supported? for streaming token usage reporting

## 0.1.6 - 2026-04-28

- Publish best-effort `llm.registry` discovered-model availability events when transport is already loaded.

## 0.1.5 - 2026-04-28

- Require current shared Legion JSON, logging, settings, and `lex-llm >= 0.1.5` runtime dependencies.

## 0.1.4 - 2026-04-28

- Require `lex-llm >= 0.1.4` so OpenAI model discovery exposes normalized capabilities and modalities.
- Cover discovered chat and embedding model metadata mapping for routing.

## 0.1.3 - 2026-04-28

- Remove the leftover compatibility entrypoint outside the Legion namespace.
- Load specs through the canonical `legion/extensions/llm/openai` namespace path.
- Keep provider gemspec dependencies scoped to the shared `lex-llm` base gem.

## 0.1.2 - 2026-04-28

- Replace fork-era namespace references with the standard Legion::Extensions::Llm provider contract.
- Remove GitHub-based lex-llm Gemfile fallback so test installs use only a guarded local path or released gem dependency.
- Require lex-llm >= 0.1.3 for the cleaned Legion-native base extension.

## 0.1.1 - 2026-04-27

- Add the OpenAI Legion::Extensions::Llm provider class with chat, streaming, model listing, model retrieval, embeddings, moderation, image, and audio transcription helpers.
- Use `Legion::Extensions::Llm::Provider::OpenAICompatible` for OpenAI-compatible request payload and response parsing.
- Use shared `Legion::Extensions::Llm.provider_settings` defaults from `lex-llm`.
- Update dependencies for shared Legion JSON, settings, logging, and `lex-llm >= 0.1.2`.
- Remove the committed `Gemfile.lock`.

## 0.1.0 - 2026-04-26

- Initial Legion LLM Openai provider extension scaffold.
