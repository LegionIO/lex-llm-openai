# Native ChatGPT subscription connections

Status: approved design; not implemented.

Approved decision: Legion owns browser/device login, durable credential storage, and token refresh. Reusing a Codex or OMP subscription login is out of scope.

Primary repository: `LegionIO/lex-llm-openai`.
Companion repository: `LegionIO/LegionIO` for the CLI.
Separate release prerequisite: restore TLS certificate verification in `LegionIO/lex-llm`.

## Problem and evidence

The OpenAI extension currently implements the public OpenAI API through `Provider::OpenAICompatible`. `Openai::InstanceDiscovery.collect_codex_candidates` copies `CredentialSources.codex_token` into `openai_api_key`, but the resulting provider still uses `https://api.openai.com` and `/v1/chat/completions`. This is credential discovery, not a working subscription adapter.

ChatGPT subscription inference uses a distinct OAuth lifecycle, account/workspace identity, account-specific model catalog, and Codex Responses wire protocol. It must not be modeled as a different string in the API-key field.

Research baseline: OMP commit `31147f9d1a76608549821c3759f8487b4d66c72d`. Source inspection establishes its protocol implementation, not live interoperability for Legion. Release requires an authenticated smoke run; no local credentials were inspected during design.

## Architecture law

The approved `nxn_rules_v2_draft.md` governs implementation. Its relevant invariants are restated here so an implementer does not need an untracked workspace file:

1. Shared execution uses shared Canonical types. Client wire is translated before execution; provider wire exists only at the provider boundary. Every defined internal type boundary rejects incompatible input.
2. Canonical request construction owns semantics; Requirements expresses them. Providers publish executable facts into Inventory. Inventory owns identity, offerings, capabilities, availability, quota domains, and published weights.
3. `Router.next_lane` consumes Requirements and one immutable Inventory snapshot and creates the authoritative Selection. Dispatch executes that Selection; it does not reroute or reconstruct it.
4. Instance identity is provider family plus the operator/configured instance name. Physical endpoints and credential fingerprints are secondary data, never replacement identity.
5. Direct and fleet execution preserve selected provider, instance, offering, lane, model, and operation. Fleet serializes/signs the exact binding, rehydrates Canonical, and verifies the binding before invoking the callable.
6. Errors are classified once at their authoritative boundary. Transient failures and quota exhaustion do not become instance-unavailable signals. Readiness owns recovery/publication.
7. Fix defects at their owner. Separate-domain defects are recorded separately. Tests must exercise the real boundary and violated invariant, not a parallel mock-only implementation.

This feature adds no routing authority, account picker, identity system, Canonical representation, or fleet protocol.

## Ownership

| Concern | Owner |
|---|---|
| ChatGPT OAuth endpoints, login, token lifecycle, account metadata | `lex-llm-openai` |
| Protected local credential records and refresh locking | Provider-local credential store in `lex-llm-openai` |
| CLI invocation and human-readable output | `LegionIO::CLI::ConnectCommand`, delegating to the extension |
| Canonical request/response/chunk/tool/usage types | Existing `lex-llm` owners |
| Codex request rendering, SSE parsing, provider errors | ChatGPT adapter in `lex-llm-openai` |
| Subscription catalog/readiness and offering evidence | `Openai::Runners::Discovery` provider hooks |
| Canonical identity, publication, weights, Selection, fleet validation | Existing shared owners, unchanged |

Provider-private authentication state is not inference execution state. Token bundles must never enter Canonical messages, Inventory records, audit payloads, or fleet envelopes.

## User interface

Proposed commands:

```sh
legion connect chatgpt --instance personal
legion connect chatgpt --instance personal --device
legion connect status --provider chatgpt --instance personal
legion connect disconnect chatgpt --instance personal
```

The CLI runs authentication locally on the credential-owning host and OS account. A daemon under another service account does not implicitly inherit the interactive user's login. For a remote/headless worker, run the device flow on that worker. Do not introduce an HTTP endpoint that returns tokens to the CLI.

`status` is a read-only inspection: it must not launch a browser or rotate a token. It distinguishes missing credentials, an unexpired login, an expired-but-refreshable login, and a known reauthentication requirement. Status is not proof of live provider readiness. `disconnect` removes the local credential and prevents future requests from using cached credentials; it does not claim to revoke the user's whole ChatGPT account or sessions in other products.

Example optional settings overrides:

```yaml
extensions:
  llm:
    openai:
      instances:
        api:
          auth_mode: api_key
          api_key: env://OPENAI_API_KEY
        personal:
          auth_mode: chatgpt
          enabled: true
```

The default for existing API-key instances remains `api_key`. Unknown modes fail validation. Native login records retain their operator-supplied instance name and can be discovered without writing tokens or an autogenerated settings file. Explicit settings can disable/configure that named instance. A configured API-key instance and a native subscription record must not silently compete for the same instance name; report the conflict and require explicit configuration correction.

Proposed extension entry points, all keyword-based:

```ruby
Legion::Extensions::Llm::Openai::Chatgpt::Auth.login(instance: 'personal', device: false)
Legion::Extensions::Llm::Openai::Chatgpt::Auth.status(instance: 'personal')
Legion::Extensions::Llm::Openai::Chatgpt::Auth.logout(instance: 'personal')
```

These return sanitized Hash results, never access/refresh tokens. Login progress communicates only the authorization URL/device code and safe status. The provider-local store supplies the current token bundle to discovery and inference internally.

## Native OAuth lifecycle

Implement the public-client browser authorization-code flow with PKCE S256 and unpredictable, one-use state. Validate callback path, state, OAuth errors, cancellation, and expiry before exchanging the code. Bind only a loopback listener; shut it down on every exit.

Observed OMP contract:

| Item | Value |
|---|---|
| Public client ID | `app_EMoamEEZ73f0CkXaXp7hrann` |
| Authorize URL | `https://auth.openai.com/oauth/authorize` |
| Token/refresh URL | `https://auth.openai.com/oauth/token` |
| Browser redirect | `http://localhost:1455/auth/callback` |
| Device initialization | `POST https://auth.openai.com/api/accounts/deviceauth/usercode` |
| Device approval page | `https://auth.openai.com/codex/device` |
| Device polling | `POST https://auth.openai.com/api/accounts/deviceauth/token` |
| Device exchange redirect | `https://auth.openai.com/deviceauth/callback` |

OMP requests `openid profile email offline_access api.connectors.read api.connectors.invoke`, plus `id_token_add_organizations=true` and `codex_cli_simplified_flow=true`. Use only scopes required for the approved inference/login feature; connector access is not a feature requirement. Validate the selected scope set in the authenticated smoke run. Use Legion's product identity rather than silently claiming to be OMP; any upstream client/originator restriction is an interoperability failure to surface, not a reason to falsify success. The observed public client ID is not a secret and does not establish a separate support or policy guarantee for third-party clients.

The browser callback URI is allowlisted in the observed implementation: a busy port must produce an actionable error, not silently switch ports. Device authentication avoids this callback. Device initiation returns `device_auth_id`, `user_code`, and an interval. Poll with cancellation and a bounded deadline; the observed device-poll protocol treats 403/404 as pending specifically at that endpoint. Do not generalize those statuses to inference or token exchange. Successful polling returns `authorization_code` and `code_verifier`, which are exchanged at the token endpoint.

Code exchange and refresh use form-encoded requests. Refresh uses `grant_type=refresh_token`, the stored refresh token, and the public client ID. Validate the access/refresh token bundle and positive expiry before accepting it. Retain optional ID-token metadata only when needed to obtain account identity; do not expose it in status.

Extract account/workspace identity from trusted token-exchange results: `https://api.openai.com/auth.chatgpt_account_id`, with ID-token fallback when necessary. Decoding a JWT for provider metadata is not local signature verification or an authorization decision. The upstream validates its tokens. Email and plan type are optional display metadata, not identity or proof of entitlement.

Refresh preserves stored account/workspace identity when omitted from a refreshed token. A contradictory account/workspace ID is an authentication conflict and must not change an existing execution binding. An explicit new login may replace an account only through credential replacement and normal Inventory reconciliation, never within a selected call.

## Credential persistence and concurrency

Use a provider-local durable store rooted at `~/.legionio/auth/llm/openai/`, separate from the existing Legion daemon-login credential file. Directory permissions are 0700; credential and stable lock files are 0600. This is protected local storage, not a claim of encryption at rest. Do not build a new generic OAuth framework or depend upward on `LegionIO::Auth::TokenManager`, whose refresh implementation is currently incomplete.

Each record contains a schema version, exact operator instance name, authentication mode, account/workspace ID, access token, refresh token, absolute expiry, and optional safe display metadata. Encode the storage filename safely without lossy normalization of instance identity; do not interpolate unchecked names into paths. Validate restrictive permissions and reject unsafe symlink targets.

Read the current durable record at the point of use. Refresh under a stable per-record process lock, reread after acquiring the lock, and skip refresh if another process already replaced the bundle. Use a short expiry margin. Write the complete successful replacement to a same-directory temporary file with restrictive permissions and atomically rename it. The lock must not be the credential file inode that is replaced. Use the same exclusion boundary for logout/replacement to prevent an in-flight refresh resurrecting a logged-out record.

A transport failure must not erase a usable credential bundle or be misreported as revocation. A definitive invalid/revoked refresh grant requires reauthentication. If upstream rotation succeeds but durable persistence fails, fail visibly; do not claim durable success or assume the previous refresh token remains usable. A process crash between server-side rotation and local persistence can require reauthentication; local locking cannot make the remote exchange transactional.

Never log token requests/responses, token values, callback authorization codes, or raw credential records. Credential files are runtime state outside the repository. Fleet workers never copy refresh bundles through AMQP.

## Provider execution and translation

Add a ChatGPT provider implementation within `Legion::Extensions::Llm::Openai`; the family remains `:openai`. Existing `Helpers::Callable` binds the appropriate implementation from the normalized instance mode at publication/construction. It must not consult mutable global settings to choose another account or auth mode after Selection.

Use the existing base provider completion funnel and strict Canonical checks. Wire the new translator into the actual `render_payload`, streaming, and synchronous hooks. A standalone translator exercised only by tests is not implementation. Do not alter the public API-key translator or translate Canonical through Chat Completions before rendering Responses.

OMP's subscription origin is `https://chatgpt.com/backend-api`, with Responses paths `/responses` and `/codex/responses`. Pin the negotiated protocol path/version in the provider adapter and verify live interoperability. An endpoint variation must never select a different model/account or fall back to `api.openai.com`.

Authentication uses the fresh OAuth bearer and `chatgpt-account-id`. Protocol negotiation includes the observed Responses beta/version/originator headers, plus account-required residency metadata. OMP's research baseline pins Codex client version `0.159.0`; this is a compatibility value to maintain, not an invented Legion version. Check actual inference requirements, including conditional attestation, in the live smoke run rather than assuming every discovery header suffices for inference. Do not disable TLS or leak credentials to an arbitrary endpoint to make connectivity work.

Use HTTP SSE with `stream: true` and `store: false`. Streaming callers receive Canonical chunks; ordinary callers accumulate the same translated stream into a Canonical response. HTTP streaming is the upstream encoding, not a change to the caller's requested response mode. Require an authoritative terminal event: EOF without completion is an incomplete response, not success. Preserve cancellation and never replay partially delivered output as an invisible retry.

Map supported Canonical text, image input, tools, tool results, tool choice, and reasoning semantics directly to Responses items. Keep thinking separate from visible text. Preserve encrypted reasoning data as opaque metadata/signature state, not visible prose. Tool call/result correlation must survive wire encoding; unsupported or malformed history fails explicitly, without invented results or interruption messages.

Map terminal completion/failure, tool completion, token/cache usage, and errors back into shared Canonical objects. Shared execution must never receive raw Responses items or legacy response wrappers.

### Unsupported semantics

OMP deliberately omits sampling controls and deletes `max_output_tokens`/`max_completion_tokens`. Legion must not copy these omissions as silent compatibility behavior. If an authoritative Canonical parameter or output requirement cannot be represented faithfully, reject it with the existing typed unsupported/invalid-request contract before upstream inference. Do not truncate output or mutate Requirements to pretend it was honored. A provider's maximum context/output capacity is not evidence that the backend supports a caller-selected output cap.

Every client dialect remains eligible to use this backend when its Canonical requirements are supported. N x N does not imply every provider can satisfy every request. If a required shared Requirements/capability representation is missing, record that separately at its shared owner; do not add a ChatGPT-specific routing branch or hash bypass.

## Discovery, Inventory, and outcomes

Use `Openai::Runners::Discovery` hooks (`fetch_raw_models`, `check_health`, `build_offering_draft`, `build_callable`, and auth/base-URL hooks) with the existing shared publication/reconciliation pipeline. Native candidate collection is a read-only credential/config inspection; authenticated readiness/catalog work obtains valid credentials through the auth owner.

The observed account-specific catalog is `/codex/models` or `/models` with `client_version`. Translate its model IDs and evidence into the existing provider publication contract. Publish only implemented operations and supported capabilities; subscription connectivity does not imply embedding, moderation, audio, image generation, computer use, or every API-key model is supported. Do not import OMP hardcoded context floors, synthetic aliases, or worker-model substitutions as authoritative facts.

Canonical instance identity remains `openai` plus the exact configured instance name. Refreshing a token does not change that identity. Keep account/workspace identity as provider metadata and quota-domain evidence; separate instances on the same subscription must not appear to have independent quota pools. Never put token strings into immutable Inventory records.

Use the existing `ProviderOutcome` taxonomy. Preserve authentication/authorization/billing errors, provider usage-limit codes and reset times, rate limits, timeout/connection failures, and malformed responses. Do not classify 429/5xx or temporary refresh failures as exact-instance unavailability. Readiness and publication own admission/removal/recovery.

An explicit subscription instance pin stays exact through direct and fleet execution. The adapter never substitutes an API-key connection or another account. Unpinned requests keep existing router policy; this feature does not redefine global escalation.

## Implementation locations

Under `lib/legion/extensions/llm/` in this repository:

- `openai.rb`: load the new components and expose normalized auth-mode defaults/options.
- `openai/instance_discovery.rb`: native login records, settings precedence/conflict checks, and removal of the ChatGPT bearer-to-API-key candidate. Preserve `OPENAI_API_KEY`, `CODEX_API_KEY`, and genuine stored API keys.
- `openai/chatgpt/auth.rb`: browser/device flow, refresh ownership, sanitized login/status/logout API.
- `openai/chatgpt/credential_store.rb`: durable record I/O and refresh/logout locking.
- `openai/chatgpt/provider.rb`: subscription-only transport hooks and account-scoped catalog/readiness methods.
- `openai/chatgpt/translator.rb`: one Canonical-to-Responses and Responses-to-Canonical boundary, used by the real provider.
- `openai/helpers/callable.rb`: exact implementation binding and authoritative outcome normalization.
- `openai/runners/discovery.rb`: subscription publication hooks; no duplicated Inventory machinery.

In `LegionIO`, update `lib/legion/cli/connect_command.rb` to delegate native login/status/disconnect to the extension. Missing extension or credential storage errors must be actionable failures, not successful no-ops. Preserve existing provider behavior.

## Alternatives and exclusions

- API-key substitution: rejected; wrong backend, protocol, and lifecycle.
- Read another harness's auth file: rejected by the approved ownership decision; would couple refresh lifecycles and risk rotation races.
- A new provider family/gem or shared OAuth framework: unnecessary for one OpenAI-specific feature; use separate named instances and provider-owned translation.
- WebSocket pooling, Responses Lite, account rotation, subscription pooling, connector tools, and synthetic model aliases: not included.
- Shared routing, Canonical, pricing, and fleet redesign: not included. Preserve usage; do not claim that subscription access makes all inference free or that API list-price estimates are actual subscription charges.

## Release prerequisites and proof

`lex-llm/lib/legion/extensions/llm/connection.rb` currently sets `faraday.ssl.verify = false`. Fix this at the shared connection owner in separate work before release. OAuth and inference must verify certificates/hostnames and support valid configured CA trust without an insecure fallback. Do not conceal the shared defect with a provider-local override.

Boundary proof must cover real login exchange/persistence/refresh, concurrent processes, callable execution, provider translation, and exact fleet serialization/signing/validation/rehydration/resolution. Public-client matrix coverage must compare equivalent supported Canonical semantics, including a multi-turn tool exchange, streaming and ordinary responses, image input where advertised, and explicit unsupported requirements. No green mock-only translator suite substitutes for these paths.

Implementation release gates include full-suite RSpec, whole-repository RuboCop, version/changelog updates in each Ruby gem changed, and a user-authorized authenticated smoke run. Development fixtures must contain no real tokens, account identifiers, or private prompts. This planning change runs no tests and changes no source.

## Sources

- [OMP OAuth declaration](https://github.com/can1357/oh-my-pi/blob/31147f9d1a76608549821c3759f8487b4d66c72d/packages/catalog/src/compat/rules/auth/openai-codex.kdl)
- [OMP OAuth implementation](https://github.com/can1357/oh-my-pi/blob/31147f9d1a76608549821c3759f8487b4d66c72d/packages/ai/src/registry/oauth/openai-codex.ts)
- [OMP subscription wire constants](https://github.com/can1357/oh-my-pi/blob/31147f9d1a76608549821c3759f8487b4d66c72d/packages/catalog/src/wire/codex.ts)
- [OMP request translation](https://github.com/can1357/oh-my-pi/blob/31147f9d1a76608549821c3759f8487b4d66c72d/packages/ai/src/providers/openai-codex/request-transformer.ts)
- [OMP account-scoped discovery](https://github.com/can1357/oh-my-pi/blob/31147f9d1a76608549821c3759f8487b4d66c72d/packages/catalog/src/discovery/codex.ts)
- [OpenAI authentication and headless sign-in](https://learn.chatgpt.com/docs/auth)

Companion plan: [implementation](2026-10-29-chatgpt-subscription-implementation.md).
