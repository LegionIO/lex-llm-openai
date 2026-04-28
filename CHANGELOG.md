# Changelog

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
