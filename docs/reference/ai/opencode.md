# opencode harness sync (`ldx opencode`)

This command configures the local [opencode](https://opencode.ai) harness (`~/.config/opencode/opencode.jsonc`) to use
the LLM models and MCP tools routed by [Bifrost](./bifrost.md). LLM models are configured as a provider named `bifrost`
(models are prefixed with `bifrost-` to distinguish them from direct omlx models), and MCP tools are configured as the
`bifrost` MCP server at `https://bifrost.rd.localhost/mcp`.

One gateway, two endpoints: opencode talks to Bifrost for both LLMs (at `/openai`) and MCP (at `/mcp`). Bifrost injects
the real upstream credentials server-side, so the harness only needs the single virtual client key.

## Model naming

Models are referenced with a clear distinction between direct and gateway-routed models:

- **Direct omlx connection**: `omlx/<model-id>` (e.g., `omlx/qwen-3.8-moe`) - if you configure a direct omlx provider
- **Bifrost gateway**: `bifrost/bifrost-<model-id>` (e.g., `bifrost/bifrost-qwen-3.8-moe`) - through the Bifrost gateway

The `bifrost-` prefix on the model key makes it clear which models are routed through Bifrost. Under the hood, OpenCode
sends `omlx/<model-id>` to Bifrost (the wire id), and Bifrost routes it to the omlx provider. This is the same pattern
as the old `agw-` prefix, but using `bifrost-` to match the new gateway name.

## Commands

### `ldx opencode sync` (alias: `setup`)

Rebuilds the `provider.bifrost` section and `mcp.bifrost` section of `~/.config/opencode/opencode.jsonc`:

1. **Model discovery**: Reads the available models from the local oMLX server (`~/.omlx/settings.json`) via
   `http://localhost:<port>/v1/models` (helper models such as `MarkItDown` and `nomicai-modernbert` are filtered out).
2. **Settings join**: Merges each model's oMLX settings - `max_tokens`, `context_window`, `temperature`, `top_p`,
   `top_k`, and reasoning configuration - into an opencode model manifest (`limit.context`, `limit.output`, `options.*`).
3. **Thinking variants**: Models with a configured `reasoning_parser` get three variants of `budgetTokens` (`low` =
   max(budget/4, 1024), `medium` = the oMLX budget, `high` = min(output, budget x 4)). Models with a thinking budget
   but no parser (e.g. Gemma 4) get `reasoningEffort` levels instead. Models with neither get no variants. When
   variants exist, the default model reference gets a `#low` suffix.
4. **Model keys**: Each model key is prefixed with `bifrost-` (e.g., `bifrost-qwen-3.8-moe-full`) to distinguish
   Bifrost-routed models from direct omlx models in the model list. The wire id (sent to Bifrost) is `omlx/<model-id>`.
5. **Default model**: Interactively chosen from the discovered models (with a numbered prompt on a TTY; the existing
   default is kept when still valid). Override with `--default-model <name>` (with or without the `bifrost-` prefix).
6. **Virtual API key**: The Bifrost virtual client key (see `ldx bifrost api-key`) is provisioned if missing and written
   to `provider.bifrost.options.apiKey`. The sync refuses to run while models are configured but no key can be
   obtained.
7. **MCP endpoint**: Configures `mcp.bifrost` in the opencode config with the Bifrost MCP endpoint
   (`https://bifrost.rd.localhost/mcp`) and the same virtual client key as `Authorization: Bearer <key>`. Bifrost
   validates the key and handles upstream authentication transparently. Any other MCP servers in the config are preserved.
   If no Bifrost key is found, MCP is skipped with a warning.
8. **Safe merge**: Everything else in `opencode.jsonc` (other providers, other MCP servers, plugins,
   `disabled_providers`, …) is preserved. A backup is written to `opencode.jsonc.bak` first, and the update is atomic.

Models that previously existed in the config but are no longer available are pruned with a warning (`--keep-stale`
keeps them). Legacy keys with `agw-` or `omlx/` prefixes are recognized and migrated to the `bifrost-` format.

**Flags**

- `--dry-run`: print the resulting provider JSON without writing anything (the API key is redacted).
- `--default-model <name>`: select the default model non-interactively.
- `--keep-stale`: do not prune models that disappeared.

## Refreshing after oMLX model changes

The manifest is a snapshot of the oMLX model list taken at sync time. The Bifrost provider uses `["*"]` for models,
so new models appear in Bifrost automatically. To make them available in opencode, re-run:

```bash
# opencode's provider.bifrost follows the live oMLX model list
ldx opencode sync
```

If the oMLX server's port or API key changed, run `ldx bifrost sync-omlx` first, then `ldx opencode sync`. Models that
Bifrost no longer routes are pruned with a warning (`--keep-stale` keeps them). The default model reference is kept
when the model is still available - pass `--default-model <name>` when it is not. Verify with
`opencode models | grep bifrost/`.

## How opencode reaches Bifrost

```
opencode ──(Bearer $BIFROST_VK_OPENCODE)──▶ https://bifrost.rd.localhost/openai   (LLM)
opencode ──(Bearer $BIFROST_VK_OPENCODE)──▶ https://bifrost.rd.localhost/mcp      (MCP)
```

- The LLM provider `baseURL` is `https://bifrost.rd.localhost/openai` (Traefik, mkcert-signed).
- `provider.bifrost.npm` is `@ai-sdk/openai-compatible`; opencode speaks the OpenAI-compatible wire format.
- The MCP endpoint is `https://bifrost.rd.localhost/mcp`; Bifrost handles OAuth brokering with upstream MCP servers.
- The same virtual client key secures both endpoints.
- The TLS certificates are issued by the local mkcert CA. If Node rejects them, export `NODE_EXTRA_CA_CERTS` pointing
  at the mkcert root CA (see `ldx-tls`).

## API key

One key is used for both LLM and MCP:

**Bifrost virtual client key**:
- Generated once as `sk-bf-<48 hex>` and cached in the host secret store as `ldx/bifrost/api_key` (macOS
  Keychain; `security find-generic-password -s ldx/bifrost/api_key -w` or `ldx bifrost api-key print`).
- Stored in the cluster Secret `bifrost-secrets` under `BIFROST_VK_OPENCODE` and referenced from the gateway config
  as `env.BIFROST_VK_OPENCODE`, so the Secret is the canonical copy and reconciles survive.
- Rotate or repair with `ldx bifrost api-key`; `ldx opencode sync` picks the new value up on the next run (delete the
  cached secret first to force regeneration).

## Example

```bash
# Provision everything: Bifrost + oMLX sync + opencode config
ldx bifrost install
ldx bifrost sync-omlx
ldx opencode sync

# Preview without writing
ldx opencode sync --dry-run

# Non-interactive default selection
ldx opencode sync --default-model qwen-3.8-moe-full

opencode models | grep bifrost/
# bifrost/bifrost-qwen-3.8-moe-full
# bifrost/bifrost-qwen-3.8-moe-full:low
# ...
```

## Notes and limitations

- Requires `kubectl` against the Rancher Desktop cluster with Bifrost installed, plus `jq` and `python3` on the host.
- Interactive default selection requires a TTY; in scripts use `--default-model`.
- The key is stored in plaintext in `~/.config/opencode/opencode.jsonc` (a 644 file). It is a virtual,
  gateway-scoped key, not an upstream credential; opencode's 0600 `auth.json` credential store may be used instead in
  the future.
- Cost fields are all zero - the models are local.
- MCP servers are not configured on install; add them through the Bifrost UI (`https://bifrost.rd.localhost`).
