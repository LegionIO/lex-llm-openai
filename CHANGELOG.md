# Changelog

## 0.1.1 - 2026-04-27

- Add the OpenAI LexLLM provider class with chat, streaming, model listing, model retrieval, embeddings, moderation, image, and audio transcription helpers.
- Use `LexLLM::Provider::OpenAICompatible` for OpenAI-compatible request payload and response parsing.
- Use shared `Legion::Extensions::Llm.provider_settings` defaults from `lex-llm`.
- Update dependencies for shared Legion JSON, settings, logging, and `lex-llm >= 0.1.2`.
- Remove the committed `Gemfile.lock`.

## 0.1.0 - 2026-04-26

- Initial Legion LLM Openai provider extension scaffold.
