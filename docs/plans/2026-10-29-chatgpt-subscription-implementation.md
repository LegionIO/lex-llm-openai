# Implement native ChatGPT subscription connections

Status: approved implementation plan; no implementation in this change.

Design: [native ChatGPT subscription connections](2026-10-29-chatgpt-subscription-design.md).

## Deliverable

A user can sign in to ChatGPT through Legion, restart Legion, refresh credentials without another harness, discover account-supported models, and execute supported Canonical requests through an exact OpenAI subscription instance. Existing API-key instances continue to work independently. Both direct and fleet execution preserve the selected instance/model/operation. Secrets never leave their credential-owning node through Inventory, logging, CLI results, or fleet envelopes.

No dependency on a Codex/OMP installation or credential store. No subscription-specific branches in routing or shared execution.

## Repository work split

| Work item | Repository | Boundary |
|---|---|---|
| Parent feature | `LegionIO/lex-llm-openai` | Native auth, storage, provider translation/transport, discovery, callable, conformance |
| CLI companion | `LegionIO/LegionIO` | `legion connect` entry points, delegation, output, CLI verification |
| TLS prerequisite | `LegionIO/lex-llm` | Restore verification in shared HTTP connection construction and prove CA/hostname behavior |

The TLS defect is separate shared-owner work, not a provider-local workaround. The feature cannot be released until it lands. No changes to published migrations are planned.

## Contract agreed before implementation

### Authentication facade

Implement under `Legion::Extensions::Llm::Openai::Chatgpt::Auth`:

```ruby
login(instance:, device: false) # -> sanitized Hash
status(instance:)               # -> sanitized Hash; no refresh/network login
logout(instance:)               # -> sanitized Hash; remove local credential
```

Login needs an explicit progress callback or equivalent extension-owned interface for an authorization URL/device code. The CLI must not duplicate OAuth logic. Neither return values nor progress events expose access/refresh/ID tokens or callback authorization codes.

Use stable result fields such as `status`, `instance`, `auth_mode`, `expires_at`, and safe account display metadata. Document the final field names in the implementation README and make the CLI consume exactly that contract. Operational auth failures remain typed errors with sanitized reasons; they are not successful empty Hash results.

### Execution boundary

The existing provider funnel consumes shared Canonical messages/tools/params and the exact selected `model:`. The ChatGPT implementation returns shared Canonical responses/chunks, not raw Responses items. New translation must be wired to the real `render_payload`, `stream_response`, and `sync_response` paths; preserve the base contract checks rather than overriding `complete` to bypass them.

`Helpers::Callable` selects the implementation from normalized instance configuration once. A credential reference supplies fresh tokens for the same account/instance; it does not select another account/model or reconstruct Selection.

### Config and identity

- Existing absent `auth_mode` means `api_key`.
- Explicit `chatgpt` uses a Legion-owned credential record, not an `openai_api_key` placeholder.
- Unsupported modes and conflicting records/configuration fail visibly.
- Login retains the exact operator instance name. Settings may disable/configure that instance.
- Token changes do not change `Inventory::Identity::InstanceKey`.
- A separate account/workspace quota-domain fact prevents duplicate named instances from masquerading as independent subscription allowances.

## Phase 1: shared TLS prerequisite

Owned by `lex-llm`:

1. Inspect `lib/legion/extensions/llm/connection.rb#initialize`, which currently sets `faraday.ssl.verify = false`.
2. Restore certificate and hostname verification in the shared owner; use standard TLS defaults and existing configuration/trust patterns. Preserve support for valid corporate/custom CA chains without silently disabling checks.
3. Inspect sibling shared HTTP connection constructors for the same defect class. Keep fixes in the shared security boundary, not in OpenAI adapters.
4. Prove the real connection rejects an untrusted certificate and a trusted-but-wrong-host certificate, and accepts a trusted matching certificate. Exercise the supported HTTP adapter configuration with a local TLS endpoint; a test asserting a boolean assignment is insufficient.
5. Apply this gem's full release gates and publish the corrected dependency. The provider's minimum dependency version must include the fix before release.

Acceptance: invalid TLS prevents any authenticated upstream exchange; there is no provider-local `verify: false` fallback.

## Phase 2: provider-owned credential lifecycle

Files to create:

- `lib/legion/extensions/llm/openai/chatgpt/auth.rb`
- `lib/legion/extensions/llm/openai/chatgpt/credential_store.rb`

Files to update:

- `lib/legion/extensions/llm/openai.rb` for requires/options/defaults
- `lib/legion/extensions/llm/openai/instance_discovery.rb` for mode-aware native candidates

Tasks:

1. Implement browser PKCE/state flow against the pinned OpenAI public-client contract in the design. Use a loopback-only listener and the exact callback URI; fail on a busy port, state mismatch, or OAuth error. Clean up on success, cancellation, timeout, and exception.
2. Implement device initialization, server-directed polling, cancellation/deadline, and authorization-code exchange. Only the device-poll endpoint treats its documented 403/404 responses as pending.
3. Validate exchange results, expiry, and account/workspace identity. Do not use email as instance or quota identity.
4. Persist complete bundles under the protected Legion-local auth directory. Use safe storage keys, restrictive permissions, stable lock files, atomic replacement, and symlink/path safety. Never reuse the daemon-login credential file.
5. Refresh under the credential record's cross-process lock. Reread after locking; return a newer valid bundle if another process refreshed it. Preserve identity; reject contradictory refreshed account metadata.
6. Coordinate logout/relogin with the same lock. A refresh must not resurrect a logged-out record. Read current durable state before using credentials, rather than retaining an indefinitely usable token in a provider object.
7. Distinguish transient token endpoint/network failures from definitive revoked/invalid grants. Do not claim persistence success after a failed disk write. Do not assume local atomic writes make the remote refresh exchange transactional.
8. Remove the OpenAI discovery mapping from ChatGPT bearer tokens to API keys. Preserve genuine API-key discovery, including `CODEX_API_KEY`. Do not delete unrelated shared probes without tracing their consumers and keeping any separate owner work explicit.
9. Ensure `enabled: false` and conflicting explicit auth modes are respected. Candidate collection remains read-only; readiness and execution obtain fresh credentials through the auth owner.

Boundary coverage to keep:

- Wrong/replayed state never reaches code exchange; a busy callback port has no arbitrary-port fallback.
- Device pending, expiry/cancellation, denial, malformed exchange, and successful login traverse actual auth logic with a local transport fixture.
- A fresh process can read the saved login; status exposes no secrets and causes no refresh.
- Two processes refreshing the same expired record cause one winning refresh/atomic bundle replacement; the waiter consumes the winner.
- Refresh racing logout does not recreate a usable login after logout completes.
- A refreshed token cannot change account identity; transient failure does not erase the prior bundle.
- Rejected permission/path/symlink cases never publish success or leak a record.

## Phase 3: subscription provider and wire translation

Files to create:

- `lib/legion/extensions/llm/openai/chatgpt/provider.rb`
- `lib/legion/extensions/llm/openai/chatgpt/translator.rb`

Files to update:

- `lib/legion/extensions/llm/openai/helpers/callable.rb`
- `lib/legion/extensions/llm/openai.rb` and provider option registration as required

Tasks:

1. Bind the subscription implementation from the normalized instance mode; preserve `:openai` family and exact selected model/instance/operation.
2. Implement direct Canonical-to-Responses rendering. Do not route through the API-key Chat Completions renderer and then convert its Hash.
3. Use the verified subscription origin/path, current bearer/account headers, required protocol version negotiation, and account-required residency/transport metadata. Confirm conditional upstream requirements before claiming live compatibility.
4. Use SSE upstream with `store: false` and `stream: true`. Accumulate the same translated event stream for ordinary calls; do not require WebSocket machinery.
5. Translate supported text, input images, tool definitions/calls/results, tool choice, and reasoning fields. Preserve tool correlation and opaque reasoning state. Do not synthesize missing tool results or silently alter history.
6. Reject nonrepresentable authoritative Canonical controls before inference, including unsupported sampling/output caps. Do not silently drop a supplied field merely because OMP does so.
7. Translate text/reasoning/tool deltas, terminal completion/failure, and usage into shared Canonical types. Detect malformed events and missing terminal completion. Honor cancellation and do not replay partially emitted output.
8. Normalize provider errors once into `ProviderOutcome`, including subscription quota codes/reset information. Authentication, authorization, billing, quota, timeout, and malformed output remain distinct. Do not treat raw 429/5xx as permanent instance failure.

Boundary coverage to keep:

- Exercise the actual callable and provider HTTP path with deterministic wire fixtures, not just the standalone translator.
- Plain Hash messages/tools are rejected at the defined internal Canonical boundary.
- Multi-turn tool call/result identity survives outbound rendering, streamed argument assembly, and the next request.
- Reasoning remains separate from visible text and opaque metadata survives replay.
- Streaming and ordinary requests produce equivalent completed Canonical semantics and usage.
- An explicit unsupported control fails before an upstream request; EOF without a terminal event is not success.
- Subscription auth/quota failure never invokes the API-key provider or a second account inside the adapter.

## Phase 4: account-specific discovery and publication

File to update:

- `lib/legion/extensions/llm/openai/runners/discovery.rb`

Use existing shared hooks and pipeline; do not introduce a second catalog/registry.

Tasks:

1. Implement subscription `fetch_raw_models` and `check_health` using fresh credentials and the account-scoped Codex catalog. Preserve the difference between a transient failed fetch and an authoritative account denial.
2. Translate catalog model IDs/context/capability evidence into existing `OfferingDraft` records. Keep unknown evidence unknown; never manufacture context limits from OMP model-specific overrides.
3. Publish only operations actually implemented and verified. A chat subscription must not inherit embeddings, moderation, audio, or image-generation eligibility from the API provider map.
4. Build the exact subscription callable and account/workspace quota-domain evidence. Publish through shared claim/activate/reconcile/replace and weight reconciliation paths.
5. On credential removal or definitive invalidity, let the owning readiness/publication path update availability. Future calls must not use a cached token while awaiting the next discovery cycle.
6. Verify token refresh retains canonical instance identity; an explicit account replacement results in normal authoritative reconciliation, not downstream selection reconstruction.

Coverage: API-key and subscription instances coexist; catalog restrictions remain per account; zero weights and explicit pins retain existing meaning; token rotation does not create a new lane identity or reset account quota identity.

## Phase 5: CLI companion

Repository: `LegionIO/LegionIO`.
File: `lib/legion/cli/connect_command.rb`, with the corresponding existing CLI specs and documentation/release metadata.

Implement:

```sh
legion connect chatgpt --instance personal
legion connect chatgpt --instance personal --device
legion connect status --provider chatgpt --instance personal
legion connect disconnect chatgpt --instance personal
```

Tasks:

1. Load the extension only when needed and call its agreed auth facade. Do not introduce a hard dependency on an installed Codex/OMP executable.
2. Display the browser URL/device instructions and sanitized status. Missing extension, failed persistence, cancellation, and OAuth rejection must not print a success message.
3. Add provider/instance selection to status/disconnect without breaking existing providers. Do not fix unrelated placeholder provider commands as part of this feature.
4. Keep auth token storage, refresh, and account decisions out of the CLI. Status must not refresh or start login.
5. Document host/OS-account ownership: a local CLI does not authenticate a different remote daemon account; use device sign-in on the target worker.
6. Verify the actual CLI surface, including exit status and no token output. Exercise local login/status/restart/disconnect; CI may substitute the upstream wire endpoint, not the CLI-to-extension delegation.

The provider and CLI implementations can proceed concurrently after the auth facade and sanitized result contract are fixed. CLI completion depends on the real provider integration, not a permanent stub.

## Phase 6: N x N and exact-execution release evidence

Existing repository anchors:

- `spec/legion/extensions/llm/openai_ssot_v3_conformance_spec.rb`
- `spec/legion/extensions/llm/openai/provider_contract_spec.rb`
- `spec/legion/extensions/llm/openai/discover_instances_spec.rb`
- `spec/legion/extensions/llm/openai/translator_spec.rb`
- `spec/legion/extensions/llm/openai/runners/fleet_worker_spec.rb`

Reuse their conventions and the shared contract harness. Add focused new auth/store/subscription specs only where a plausible bug would violate an observable invariant. Do not preserve wording/source-text/wiring-only assertions by repinning them.

Required end-to-end scenarios:

1. Chat Completions, Responses, and Anthropic Messages client paths express equivalent supported semantics, reach shared Canonical state, and execute the same pinned subscription offering. Separately verify explicit unsupported semantics fail; do not weaken Canonical to force the matrix green.
2. Each client-facing mode receives text and a complete tool exchange in its expected wire dialect, with correct completion and usage. Streaming and ordinary callers are both exercised.
3. Direct dispatch preserves the selected tuple. Fleet exercises actual envelope serialization, signing, validation, Canonical rehydration, exact Inventory resolution, and callable invocation. A binding mismatch raises before provider HTTP execution.
4. A subscription-pinned quota/auth failure never silently becomes an API-key request. Unpinned escalation remains the existing router's decision.
5. Refresh across process restart and concurrency works without changing canonical identity or placing secrets in transport/logs.
6. API-key regression coverage remains green.

Where the public-client matrix harness resides in `legion-llm`, use it for an integration smoke without expanding this feature into router/client-translator changes. A discovered shared defect must be recorded and resolved by its owner before claiming the affected path works.

Authenticated smoke requires an approved eligible ChatGPT account: complete native login, fetch its actual catalog, choose one published model exactly, execute a simple response plus a tool exchange and streaming response, and inspect sanitized outcomes. Validate the proposed Legion originator/scopes and any account-required protocol features. No real credentials belong in fixtures or issue attachments. Do not claim this smoke passed based on OMP source inspection.

Before commit/push of implementation, follow the workspace `rspec`, `rubocop`, and `ruby-release-gate` workflows: full `bundle exec rspec` with output to files, whole-repository `bundle exec rubocop -A`, no skipped unrelated failures, and version/CHANGELOG updates for every changed gem. This documentation-only intake does not run those commands.

## Completion and cleanup

After the live path and boundary checks succeed, update the existing README/configuration examples with actual commands, storage permissions, service-account ownership, supported operations, unsupported controls, and reauthentication behavior. Remove temporary smoke artifacts and ensure no tokens/prompts were committed. Record verification evidence and remaining separately owned blockers in the parent issue.

Do not mark complete with login-only support, an unused translator, only mocked dispatch, silently dropped requirements, or an unverified fleet binding. The final deliverable includes the native lifecycle and real provider path defined above.
