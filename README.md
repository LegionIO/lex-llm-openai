# lex-llm-openai

OpenAI provider extension for LegionIO. Version **0.6.7**.

**Namespace:** `Legion::Extensions::Llm::Openai`  
**Load:** `require 'legion/extensions/llm/openai'`

Two authentication modes share the `:openai` family but remain independently named and selected:

| Mode | Credentials | Provider boundary |
|---|---|---|
| `api_key` (default) | Existing OpenAI API-key configuration | OpenAI-compatible API |
| `chatgpt` | A native, named Legion OAuth login | ChatGPT subscription Responses backend |

A ChatGPT subscription is not an OpenAI API key. The extension never substitutes one mode, account, instance, or model for another after dispatch fails.

## API-Key Usage

Existing API-key discovery and operations remain available: chat, streaming, embeddings, moderation, images, and supported audio operations.

The direct provider boundary accepts Canonical messages and an explicit selected model:

```ruby
require 'legion/extensions/llm/openai'

provider = Legion::Extensions::Llm::Openai::Provider.new(
  { openai_api_key: ENV.fetch('OPENAI_API_KEY') }
)
messages = [
  Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Hello')
]
response = provider.chat(messages, model: 'gpt-4o')
puts response.text
```

Daemon execution should use Legion's existing Router and exact dispatch path. Provider implementations do not choose a default or replacement model.

## Native ChatGPT Login

The provider owns login, refresh, status, and logout. The CLI companion is tracked separately in [LegionIO#249](https://github.com/LegionIO/LegionIO/issues/249); the commands proposed there are not implemented by this gem.

### Configuration and TLS

Subscription catalog and inference requests require **`lex-llm >= 0.8.5`** and **`extensions.llm.ssl.verify: true`**. The shared default remains `false`; subscription execution fails clearly unless it is explicitly enabled. There is no provider-local TLS-verification override.

Merge this into the normal Legion settings tree:

```json
{
  "extensions": {
    "llm": {
      "ssl": { "verify": true },
      "openai": {
        "chatgpt": {
          "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"
        },
        "instances": {
          "personal": { "auth_mode": "chatgpt" }
        }
      }
    }
  }
}
```

Keep existing API-key instances unchanged. An `OPENAI_API_KEY` environment credential and the native `personal` login remain separate candidates. Native logins are discoverable without an explicit instance entry; configuration is useful for disabling an instance or setting existing weight/fleet options.

`extensions.llm.openai.chatgpt.client_id` is the public OAuth application ID used for browser authorization, device authorization, and token refresh. It defaults to the value shown above; omit `chatgpt` to keep that default. Override it with an OpenAI-registered client that supports the existing authorization flows and redirect URIs. After changing it, log in again: existing refresh tokens belong to the previous OAuth application. An in-progress login retains the client ID it started with.

OAuth grant requests use verified HTTPS independently of the inference connection setting. Fix certificate trust at the system/shared transport owner, not by disabling verification for native subscription traffic.

### Browser and Device Authorization

Browser flow:

```ruby
Legion::Extensions::Llm::Openai::Chatgpt::Auth.login(instance: 'personal') do |progress|
  puts progress.fetch(:authorization_url)
end
```

Open the supplied URL in a browser. The flow uses PKCE S256 and a single-use state, with the fixed registered callback `http://localhost:1455/auth/callback`. An occupied port fails rather than silently changing redirect URLs.

For a headless host, use device authorization:

```ruby
Legion::Extensions::Llm::Openai::Chatgpt::Auth.login(instance: 'personal', device: true) do |progress|
  puts progress.fetch(:verification_uri)
  puts progress.fetch(:user_code)
end
```

`login` accepts `timeout:` in seconds (default 600, maximum 1800) and an optional `cancelled:` callable. Callback waits, device polling, and credential-lock waits honor cancellation/deadlines. Progress events contain the information needed for user approval, not access or refresh tokens. Do not persist authorization URLs or device codes in application logs.

### Status and Disconnect

```ruby
Legion::Extensions::Llm::Openai::Chatgpt::Auth.status(instance: 'personal')
Legion::Extensions::Llm::Openai::Chatgpt::Auth.instances
Legion::Extensions::Llm::Openai::Chatgpt::Auth.logout(instance: 'personal')
```

Status reads are local and do not refresh credentials. Results contain only:

- `instance`, `auth_mode`, `status`
- `account_id`, `workspace_id`, `expires_at`

Status values are strings: `missing`, `authenticated`, `expired_refreshable`, or `reauth_required`. `instances` is keyed by the original instance name and excludes logged-out tombstones. Successful logout returns `missing`.

### Credential Ownership and Lifecycle

Records live under `~/.legionio/auth/llm/openai/`, with reversible filename-safe encoding of exact instance names. Run login as the same OS user that runs Legion; another service account does not share the operator's home directory.

- Auth directories require mode `0700`; regular record and stable lock files require `0600`, correct ownership, and a single link.
- Symlinked paths, hardlinked records/locks, unsafe permissions, and invalid records fail closed. Existing nonsensitive settings ancestors are not silently chmodded.
- Refresh rereads under a cross-process lock and atomically commits the replacement access token, refresh token, expiry, and identity before returning it.
- Omitted refresh identity metadata is preserved. Contradictory account/workspace metadata is rejected; the selected account never changes implicitly.
- Transient refresh failures retain the previous bundle. Definitively revoked grants require reauthentication.
- Logout removes credentials while retaining a token-free generation barrier so a pending login cannot resurrect them. Concurrent refresh, replacement, and logout share the stable lock.

Never copy native token bundles into settings, inventory, telemetry, or fleet messages. No Codex/OMP subscription credential import or background copying is performed.

## Subscription Requests and Evidence

`Chatgpt::Provider` uses the inherited `lex-llm` constructor, completion funnel, and shared `Connection`. Its translator maps Canonical values directly to `https://chatgpt.com/backend-api/codex/responses`; requests use the exact selected model, `stream: true`, and `store: false`. Ordinary responses and streaming responses consume the same incremental SSE decoder.

Supported provider-boundary behavior includes text, supported user images, function definitions and choices, correlated tool results, reasoning controls that the protocol can represent, opaque encrypted reasoning replay, usage, and explicit terminal/error states. Tool call IDs and opaque reasoning are not rewritten. A missing terminal response is an error, not a successful empty completion. Failed requests are not replayed by the provider.

Encrypted reasoning is retained in `Response.metadata[:reasoning_items]` and `Thinking.metadata[:reasoning_items]`. A continuation `Canonical::Message` must preserve that state in `metadata[:reasoning_items]` (or its thinking content block metadata). Shared conversation/tool-loop code owns this continuation; the provider cannot reconstruct discarded opaque state.

Explicit unsupported controls fail before credentials or inference HTTP are used. These include sampling controls, output token caps, stop sequences, penalties, seeds, output schemas/response formats, authoritative thinking budgets, extra request metadata, prompt-cache breakpoints, unsupported tool controls/content, and caller header overrides. They are not silently discarded to make a request appear successful.

The account catalog comes from `codex/models?client_version=0.159.0`. Hidden entries are excluded; exact returned IDs are preserved. There are no synthetic model aliases or invented limit floors.

- Only `chat` and `stream_chat` are published for subscription instances.
- Context, vision, tools, and reasoning evidence comes from explicit account-catalog fields; absent evidence stays unknown.
- The API-key provider's static capability map is never applied to subscription models.
- Account/workspace identity determines the subscription quota domain. Different operator names remain distinct instances but share quota exclusions when they use the same account/workspace.
- Credential rotation does not change routing identity. Account replacement requires a newly published binding; an already selected callable refuses the replacement account.

## Discovery and Fleet Ownership

API-key discovery retains `OPENAI_API_KEY`, `CODEX_API_KEY`, genuine Codex OpenAI keys, Claude `openaiApiKey`, extension-level settings, and named configured instances. Codex subscription bearer tokens are no longer misclassified as API keys. Existing shared credential-source probing controls still apply to those API-key sources.

Native logins add candidates under their exact operator names. Explicit `enabled: false` disables a candidate. Conflicting API-key/native names or configured identities raise a configuration error rather than silently renaming or substituting accounts.

`Runners::Discovery` uses the shared `Discovery::Pipeline` / `Inventory::Publisher` lifecycle. `Helpers::Callable` binds the authentication implementation once. Router, inventory identity, signed fleet envelopes, receiver validation, and Canonical rehydration remain shared-owner responsibilities. Fleet messages carry selected identity and request data, never OAuth credentials.

## Release Gates and Known Shared Dependencies

This implementation has local HTTP-fixture proof, not authenticated upstream compatibility certification. Release remains gated by:

1. Shared TLS setting delivery: [lex-llm#51](https://github.com/LegionIO/lex-llm/pull/51), with verification explicitly enabled.
2. CLI connection/status/disconnect integration: [LegionIO#249](https://github.com/LegionIO/LegionIO/issues/249).
3. Shared `lex-llm` fleet tool-definition rehydration: serialized tool hashes currently reach the strict provider boundary without becoming `Canonical::ToolDefinition` values.
4. Shared `legion-llm` native tool-loop preservation of encrypted reasoning metadata, and client stream adaptation of Hash tool fragments. The current runtime drops that state at those two boundaries.
5. Authorized live browser/device login, restart/refresh/logout, account catalog, ordinary/streaming inference, and multi-turn tool verification.

The provider does not bypass these shared boundaries. [Issue #16](https://github.com/LegionIO/lex-llm-openai/issues/16) remains the end-to-end acceptance tracker.

## Development

Runtime dependencies include `lex-llm >= 0.8.5`, `legion-settings >= 1.4.2`, `legion-transport >= 1.4.14`, `legion-json >= 1.2.1`, and `legion-logging >= 1.3.2`. There is no runtime dependency on `legion-llm`.

The test bundle resolves the adjacent `lex-llm` checkout when available. Native regressions use synthetic credentials, real temporary stores, local HTTP peers, and real shared provider/fleet boundaries; no real account is needed.

```sh
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

Capture remaining test-process stdout/stderr to local files when running the release gate. Do not inspect or print successful RSpec output; extract only failed examples when the exit status is nonzero.

## License

MIT
