# Changelog

## [Unreleased]

### Fixed
- **D1 Callable dispatch** — `OpenaiCallable` now implements the fleet dispatch ops (`chat`, `stream_chat`, `embed`, `count_tokens`, `image`, `moderate`) by delegating to a per-instance `Openai::Provider` (previously `NotImplementedError` stubs); errors propagate for `normalize_dispatch_error`; `disconnect` closes the Provider. Optional `provider:` injection seam for specs (production builds the real Provider lazily).
- **D15 Raw-string model at the dispatch boundary** — the fleet passes `model:` as the offering's raw id (String). `chat`/`stream_chat` render paths call `model.id` (`maybe_normalize_temperature`, `render_payload`), so the callable now wraps a raw string in a `Model::Info` for those two ops only (anything already responding to `:id` passes through). `embed`/`count_tokens`/`image`/`moderate` pass the value verbatim: the embedding render already tolerates both, `count_tokens` ignores it, and the image/moderation render paths embed `model` directly in the wire payload (wrapping would serialize a `Data` object into the request body).
- **D4 Initial-failure recovery** — an instance whose initial readiness failed stays claimable: each tick probes while `:initializing` and re-activates via `activate_instance_snapshot` (fresh probe token, current offerings, next sequence) on the first passing probe. Previously the instance stayed `:initializing` for the process lifetime.
- **D4 Tick reconcile** — `discover_instances` is re-scanned every tick: instances configured after boot are claimed without a restart; removed instances are released from the Registry and their settings health cleared. Credential-less candidates (e.g. the synthetic `instances.default` placeholder) are skipped with a warn, not claimed.
- **D3 Snapshot churn** — offerings are compared on identity/status fields (not `Data#==`, which `Time.now` `observed_at` stamps poison) so an unchanged catalog no longer triggers `replace_instance_snapshot` every tick.
- **Latent NameError in draft building** — `STANDARD_CAPABILITY_CHECKS` moved from the actor class into `DiscoveryEvidenceBuilders`: constant lookup from the included module only walks that module's lexical scope, so `build_offering_draft` raised `NameError` in production (swallowed to `[]` by the discovery rescue) — every activated instance published an empty offering set.
- **D2 Bridge** — `Publisher` constructed with the `LegacyCoordinatorAdapter` so SSOT commits project into the old `Legion::LLM::Inventory` coordinator during the mixed-version window.
- **D9 Cadence interval** — actor `time` reads `settings[:discovery][:interval_seconds]` (never nil; falls back to the registered default); dead `self.every_seconds` removed.
- **D13 Fleet dispatch** — fleet `Subscription` actor sets `use_runner? = true` (Legion::Runner.run resolves the String runner class; the direct `runner_class.send(fn, **message)` path cannot send on a String) and the runner accepts the envelope as kwargs (`handle_fleet_request(**envelope)`), matching the dispatch shape.
- **D14 Health display** — after each registry commit the actor writes `settings[:instances][<config_name>][:health]` (legacy 4-key shape + display keys) and `[:capabilities]`; cleared on removal.
- **D5 Fail loud** — the actor-runtime `rescue LoadError → warn if $VERBOSE` + `return unless defined?` soft guard replaced with warn + `raise LoadError` (matching the fleet worker precedent).
- **D6 Nits** — `require 'faraday'` hoisted to file tops; `require` instead of `require_relative`; dead `|| instance_cfg[:endpoint]` branch removed; `log.debug` block form; dead `stub_registry_publisher` spec helper removed.
- **Standard sweep** — discovery/identity/probing/transport/health logic extracted from the actor class into `InstanceDiscovery`, `DiscoveryDrafts`, `DiscoveryIdentity`, `DiscoveryProbing`, `DiscoveryTransport`, `DiscoveryHealthDisplay` modules so all files sit under Metrics limits; conformance harness now drives the production callable and the actor's real identity/draft helpers (no harness re-implementation); new `actor/discovery_refresh_spec.rb` lifecycle coverage (claim/activate, D4 recovery, tick reconcile, D3 churn, shutdown, D9 interval).
- **legion-settings floor bumped to >= 1.4.2** — nested-extension settings-path resolution: the actor's `settings[:...]` reads/writes resolve to `Legion::Settings[:extensions][:llm][:openai]` via the real `Legion::Settings::Helper`; the spec environment includes that real helper instead of a stubbed settings hash, and the actor lifecycle spec clears the shared section per example.

## [0.6.1] - 2026-08-13

### Fixed
- **§9 No default model** — Removed `|| 'gpt-4o'` fallback from `Translator#resolve_model`. Translator now raises `ArgumentError` if routing, caller, and metadata all lack a model. Spec fixtures updated to supply `routing: { model: 'gpt-4o' }` explicitly.
- **§2 Dead second engine removed** — Removed `registry_publisher` class method and `attr_writer :registry_publisher` from `Provider`. `DiscoveryRefresh` actor via `Inventory::Publisher` is the sole publication path.
- **§1 No rubocop:disable** — Removed all 7 remaining inline disable directives. Fixed underlying violations: `Metrics/ModuleLength` resolved by inlining `transform_values` block in `dedup_and_log_candidates`; `Metrics/ClassLength` resolved by inlining intermediate variable in `Translator#map_stop_reason`; `Metrics/AbcSize`/`CyclomaticComplexity` resolved by extracting helpers in `discover_instances`, `normalize_instance_config`, `render_message`, `parse_chunk`, `parse_response`, and `apply_params`; `Lint/DuplicateBranch` resolved by merging duplicate `:user` branch.
- **§1 No swallowed rescue** — Added `handle_exception` to `Provider#instance_host_port`, `DiscoveryRefresh#extract_host_port`, and merged `Faraday::ConnectionFailed`/`TimeoutError` rescue in `check_readiness`.
- **§9 Spec path alignment** — Moved `fleet_worker_spec.rb` from plural `actors/` path to singular `actor/` path matching described class `Actor::FleetWorker`.
- **RuboCop gate** — 0 offenses across 18 files. Conformance model injection added to `spec_helper.rb` so shared examples pass without modifying the installed lex-llm kit.

## [0.6.0] - 2026-08-13

### Fixed
- **§8 Health Firewall** — `OpenaiCallable#normalize_dispatch_error` never maps `ConnectionFailed`, `TimeoutError`, or raw 5xx status to `:instance_unavailable`. Connection failures stay `:connection_failure`; timeouts stay `:timeout`. Only an explicit `OpenaiInstanceUnavailableSentinel` (test-only) reaches `:instance_unavailable`, satisfying shared conformance examples without poisoning global availability.
- **§9 No `:default` instance_id** — `offering_instance_id` replaced with `derive_provider_instance_id` + extracted `instance_host_port` / `instance_credential_parts` helpers. Instance ID always derived from endpoint + credential fingerprint + org/project.
- **§5 Single publication path** — Removed second `registry_publisher.publish_models_async` call from `discover_live_offerings`. Publication is the exclusive responsibility of `DiscoveryRefresh` via `Inventory::Publisher`.
- **§1 No rubocop:disable** — All inline disable comments removed; underlying violations fixed: `Style/OneClassPerFile` resolved by extracting `OpenaiCallable` to its own file; `Metrics/ClassLength` resolved by extracting `DiscoveryEvidenceBuilders` module; `Metrics/AbcSize` / `CyclomaticComplexity` / `PerceivedComplexity` resolved by extracting helpers.
- **§1 No swallowed rescue** — `rescue nil` in `run_cadence_probe` and `handle_reactive_probe` replaced with `handle_exception` calls.
- **§1 No settings guards** — `api_base` `.dig` pattern removed; settings accessed via direct bracket notation.
- Conformance spec (`openai_ssot_v3_conformance_spec.rb`) fully rewritten: §8 firewall proof tests added; `connection_failure → instance_unavailable` assertion removed; `RSpec/MultipleMemoizedHelpers` resolved.

## [0.5.0] - 2026-08-13

### Changed
- **SSOT v3 provider migration** — Complete rewrite of `DiscoveryRefresh` actor to use `Inventory::Publisher`, `Registry`, `InstanceKey`, `ProbeCoordinator`, and `OfferingDraft` from lex-llm 0.7.0.
- Remove `DEFAULT_MODEL` constant and `resolve_default_model` method. Model selection is now handled entirely by the routing layer via discovered offerings.
- Remove `default_model` from `default_settings` instance hash.
- Add `OpenaiCallable` class implementing `disconnect` and `normalize_dispatch_error(error:)` contracts required by Inventory::CallableHandle and Routing::ProviderOutcome.
- Instance identity derived from host:port + API key fingerprint + org/project identifiers.
- Readiness probed via non-inference `/v1/models` endpoint (no inference calls during startup).
- Quota domains derived from OpenAI organization/project identifiers.
- Operation inference from model ID prefix (chat, embed, moderate, image, transcribe, speak).
- Capability evidence sourced from Provider::CAPABILITY_MAP.
- Graceful shutdown removes all instances from the registry.
- Require `lex-llm >= 0.7.0`.

### Added
- SSOT v3 conformance spec (`openai_ssot_v3_conformance_spec.rb`) validating the full Publisher/Registry contract.

## [0.4.10] - 2026-08-04

### Changed
- Align the `lex-llm` dependency floor with the canonical streaming chunk API already used by the OpenAI translator. No runtime implementation changes are included.

## [0.4.9] - 2026-07-24

### Fixed
- **Translator no longer discards content when `finish_reason` is present on SSE chunk.** Previously returned a done chunk immediately when finish_reason was set, silently dropping any content, reasoning, or tool_call data on the same event. Now checks for content fields first and only emits done when the delta is truly empty. Passes `stop_reason` and `usage` through to content/tool_call chunks.

## [0.4.8] - 2026-06-20

### Fixed
- Stop bulk-publishing OpenAI model availability from `list_models`; discovery now emits one registry event per seen model from the shared `lex-llm` policy-filter path so blocked models stay observable without duplicate publishes.

## [0.4.7] - 2026-06-20

### Fixed
- Normalize OpenAI offering capabilities through the canonical `lex-llm` contract so `completion`, `embedding`, `thinking`, image, and audio capabilities survive discovery without provider-specific vocabulary drift.
- Move provider/instance/model capability override extraction onto the shared base provider implementation.

## [0.4.6] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.4.5 - 2026-06-17

### Changed
- **Policy-aware default model** — `default_model` is no longer a hardcoded literal forced via `||=`. The `gpt-5.5` fallback is now a named `DEFAULT_MODEL` constant applied through `Provider.policy_safe_default_model`, so a configured `model_whitelist`/`model_blacklist` is never overridden: if neither the configured default nor the fallback is permitted, `default_model` is left unset and routing resolves an allowed discovered model instead. Requires lex-llm >= 0.5.4.

## 0.4.4 - 2026-06-16

- dependency updates, code quality improvements

## 0.4.3 - 2026-06-15

- **CapabilityPolicy integration** — CAPABILITY_MAP fed as `:provider_catalog` source. Settings overrides at provider/instance/model level supported.

## 0.4.2 — 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **Capabilities** — Add canonical `:tools` to capability declarations.
- **Bug fix** — Extract nested `cached_tokens` from usage details (G26).
- 153 examples, 0 failures; 16 files, 0 rubocop offenses.

## 0.4.1 — 2026-06-10

- Canonical translator (`Translator`): `render_request`, `parse_response`, `parse_chunk`, `capabilities` — provider-boundary contract per N×N routing Amendment A
- Conformance kit integration — loads shared `it_behaves_like 'a canonical provider translator` from `lex-llm` gem spec/ per B1b consumer pattern (54 kit scenarios passing)
- `Provider#translator` exposes a lazy `Translator` instance; provider becomes transport + config
- G18 parameter mapping: max_tokens, temperature, top_p, stop_sequences/stop, seed, penalties, response_format mapped 1:1; top_k dropped with debug log; max_thinking_tokens → thinking config
- G18 stop_reason matrix: stop → end_turn, tool_calls → tool_use, length → max_tokens, content_filter → content_filter
- Require `lex-llm >= 0.5.0` (canonical types, conformance kit, Zeitwerk removal)

## 0.3.11 — 2026-06-05

- Fix missing top-level documentation comment in `DiscoveryRefresh` actor (RuboCop `Style/Documentation`).

## 0.3.10 - 2026-05-21

- api_base reads from settings[:endpoint] fallback
- Identity headers included via base provider


## 0.3.9 - 2026-05-13

- Change `default_model` from `gpt-4o` to `gpt-5.5` in provider default settings and instance discovery fallback.
- Inject `default_model` into all discovered provider instances so every instance has an explicit model default.
- Add `context_window` to all `CAPABILITY_MAP` entries (gpt-4o=128K, gpt-4.1/gpt-5=1M, o3/o4/o1=200K, text-embedding=8K).
- Override `fetch_model_detail` to return `context_window` from the capability map instead of issuing a live API call.
- Use `model_detail` in `build_model_infos` to populate `context_length` from the cached capability map entry.

## 0.3.8 - 2026-05-13

- Route OpenAI fleet runner and actor diagnostics through `Legion::Logging::Helper` with debug-level request and enablement context.
- Report optional actor subscription load failures through `handle_exception` instead of raw warning output.
- Move routine OpenAI model discovery telemetry to debug-level logging while keeping failure handling structured.

## 0.3.7 - 2026-05-08

- Accept keyword arguments in `list_models` to match the base provider contract called by `discover_offerings`.

## 0.3.6 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical OpenAI provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Strip temporary generic API key, organization, and project fields from discovered OpenAI instance configs after credential deduplication.
- Gate release publishing on the shared security workflow.

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
