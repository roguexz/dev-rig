# opencode harness sync (`ldx opencode`)

This command configures the local [opencode](https://opencode.ai) harness (`~/.config/opencode/opencode.jsonc`) to
use the LLM models routed by [agentgateway](./agentgateway.md) as a provider named `local`, joined with the per-model
generation settings from the local oMLX server (`~/.omlx/model_settings.json`).

agentgateway is the single entry point: opencode talks only to `https://agentgateway.rd.localhost/v1` with the gateway's
virtual client API key, and the gateway injects the real upstream (oMLX) credentials server-side.

## Commands

### `ldx opencode sync` (alias: `setup`)

Rebuilds the `provider.local` section of `~/.config/opencode/opencode.jsonc`:

1. **Model discovery**: Reads the LLM route names from the agentgateway ConfigMap (`agentgateway-llm-models`,
   namespace `commons`) via kubectl (Rancher Desktop context). Helpers (embedding models, MarkItDown, ModernBERT) are
   filtered out.
2. **Settings join**: Merges each model's oMLX settings — `max_tokens`, `context_window`, `temperature`,
   `top_p`, `top_k`, and reasoning configuration — into an opencode model cost/tracking manifest (`limit.context`,
   `limit.output`, `options.*`).
3. **Thinking variants**: Models with a configured `reasoning_parser` get three variants of `budgetTokens`
   (`low` = max (budget/4, 1024), `medium` = the oMLX budget, `high` = min (output, budget x 4)). Models with a
   thinking budget but no parser (e.g. Gemma 4) get `reasoningEffort` levels instead. Models with neither get no
   variants. When variants exist, the default model reference gets a `#low` suffix.
4. **Model ids**: Each model key is prefixed with `agw-` (e.g. `agw-qwen-3.8-moe-full`) to avoid id collisions with
   other providers; the manifest keeps the unprefixed gateway route name in `"id"`, so requests still route unchanged
   through the gateway.
5. **Default model**: Interactively chosen from the discovered models (with a numbered prompt on a TTY; the existing
   default is kept when still valid). Override with `--default-model <name>` (with or without the `agw-` prefix).
6. **Virtual API key**: The gateway client key (see `ldx agentgateway api-key`) is provisioned if missing and written
   to `provider.local.options.apiKey`. The sync refuses to run while models are configured but no key can be
   obtained.
7. **Safe merge**: Everything else in `opencode.jsonc` (other providers, MCP servers, plugins, `disabled_providers`,
   …) is preserved. A timestamped `.bak` copy is written first, and the update is atomic.

Models that previously existed in the config but are no longer routed by the gateway are pruned with a warning
(`--keep-stale` keeps them).

**Flags**

- `--dry-run`: print the resulting `provider.local` JSON without writing anything (the API key is redacted).
- `--default-model <name>`: select the default model non-interactively.
- `--keep-stale`: do not prune models that disappeared from the gateway.

## How opencode reaches the gateway

```
opencode ──(Bearer $AGENTGATEWAY_API_KEY)──▶ https://agentgateway.rd.localhost/v1
                                                  │  api-key policy enforced
                                                  ▼
                                          oMLX :8080 ──▶ loaded models
```

- The provider `baseURL` is `https://agentgateway.rd.localhost/v1` (Traefik, mkcert-signed).
- `provider.local.api` is `openai`; opencode speaks the OpenAI-compatible wire format.
- The TLS certificate is issued by the local mkcert CA. If Node rejects it, export
  `NODE_EXTRA_CA_CERTS` pointing at the mkcert root CA (see `ldx-tls`).

## API key

The key opencode uses is the gateway's **virtual client key** — not oMLX's own key:

- Generated once as `agw-<48 hex>` and cached at `~/.cache/local-dev/agentgateway/api_key` (mode `0600`).
- Stored in the cluster Secret `agentgateway-secrets` under `AGENTGATEWAY_API_KEY` and referenced from the gateway
  config as `$AGENTGATEWAY_API_KEY`, so the Secret is the canonical copy and reconciles survive.
- Rotate or repair with `ldx agentgateway api-key`; `ldx opencode sync` picks the new value up on the next run (delete
  the local cache file first to force regeneration).

## Example

```bash
# Provision everything: gateway + key + opencode config
ldx agentgateway install
ldx opencode sync

# Preview without writing
ldx opencode sync --dry-run

# Non-interactive default selection
ldx opencode sync --default-model qwen-3.8-moe-full

opencode models | grep local/
# local/agw-qwen-3.8-moe-full
# local/agw-qwen-3.8-moe-full:low
# ...
```

## Notes and limitations

- Requires `kubectl` against the Rancher Desktop cluster with agentgateway installed, plus `jq` and `python3` on the
  host.
- Interactive default selection requires a TTY; in scripts use `--default-model`.
- The key is stored in plaintext in `~/.config/opencode/opencode.jsonc` (a 644 file). It is a virtual,
  gateway-scoped key, not an upstream credential; opencode's 0600 `auth.json` credential store may be used instead in
  the future.
- Cost fields are all zero — the models are local.
