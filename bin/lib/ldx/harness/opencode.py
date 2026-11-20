"""opencode harness adapter (rendering half of 'ldx opencode sync').

Ported from the python heredocs in bin/commands/ldx-opencode; the bash
command keeps the cluster reads (kubectl/jq) and the interactive model
picker, and calls:

    python3 -m ldx.harness.opencode current-default
    python3 -m ldx.harness.opencode build-manifest      # model ids on stdin
    python3 -m ldx.harness.opencode merge

The env interface mirrors the old heredocs so the bash side stays a thin
wrapper (see main() for the exact variables).
"""

import fnmatch
import glob
import json
import os
import sys

from ldx import jsonc

# Helper (non-LLM) models served by omlx but useless as coding models; same
# exclusion list as ldx-bifrost sync-omlx, extended with embeddings.
_HELPER_PATTERNS = ("MarkItDown", "nomicai-modernbert", "*modernbert*",
                    "*embedding*", "*embed*")


def is_helper_model(model_id):
    return any(fnmatch.fnmatchcase(model_id, pat) for pat in _HELPER_PATTERNS)


def current_default(config_path, provider_id):
    """Model id (no provider prefix, no #variant, no bifrost- prefix) of the
    configured default for provider_id, or None."""
    try:
        with open(config_path, encoding="utf-8") as fh:
            cfg = jsonc.loads(fh.read())
    except (OSError, ValueError):
        return None

    model = cfg.get("model") or ""
    if "/" not in model:
        return None
    provider, rest = model.split("/", 1)
    if provider != provider_id:
        return None
    mid = rest.split("#", 1)[0]
    # Config keys carry the 'bifrost-' prefix (to distinguish from direct
    # omlx models). Handle legacy prefixes for backward compatibility.
    if mid.startswith("bifrost-"):
        mid = mid[len("bifrost-"):]
    elif mid.startswith("omlx/"):
        mid = mid[len("omlx/"):]
    elif mid.startswith("agw-"):
        mid = mid[len("agw-"):]
    return mid


def _humanize(word):
    if word.lower() == "moe":
        return "MoE"
    return word.capitalize()


def model_manifest_entry(model_id, settings, mset, models_dir):
    """Manifest entry for one model id, or None when the model is unknown
    to omlx settings (e.g. removed there but still routed) or hidden: the
    harness should only offer fully-configured models."""
    # Match by alias first, then by model folder name.
    entry, folder = None, model_id
    for key, value in mset.items():
        if value.get("model_alias") == model_id or key == model_id:
            entry, folder = value, key
            break
    if entry is None or entry.get("is_hidden"):
        return None

    sampling = settings.get("sampling", {})
    context = entry.get("max_context_window") or sampling.get("max_context_window") or 8192
    output = sampling.get("max_tokens") or 8192

    # Vision: probe the model config.json for vision_*/image_* keys.
    vision = False
    pattern = os.path.join(models_dir, "*", folder, "config.json")
    for path in glob.glob(pattern):
        try:
            with open(path, encoding="utf-8") as fh:
                conf = json.load(fh)
        except (OSError, ValueError):
            continue
        if any(k.startswith("vision") or k.startswith("image_") for k in conf):
            vision = True
            break

    return {
        "id": model_id,
        # Display name: humanize the id (qwen-3.8-moe-full -> Qwen 3.8 MoE Full).
        "name": " ".join(_humanize(w) for w in model_id.split("-")),
        "vision": vision,
        "context": context,
        "output": output,
        "parser": bool(entry.get("reasoning_parser")),
        "budget_enabled": bool(entry.get("thinking_budget_enabled")),
        "budget": entry.get("thinking_budget_tokens") or 4096,
    }


def build_manifest(model_ids, settings_path, model_settings_path, models_dir):
    """One JSON object per line for every usable model; helpers, unknown and
    hidden entries are skipped."""
    with open(settings_path, encoding="utf-8") as fh:
        settings = json.load(fh)
    with open(model_settings_path, encoding="utf-8") as fh:
        mset = json.load(fh).get("models", {})

    lines = []
    for model_id in model_ids:
        model_id = model_id.strip()
        if not model_id or is_helper_model(model_id):
            continue
        entry = model_manifest_entry(model_id, settings, mset, models_dir)
        if entry is not None:
            lines.append(json.dumps(entry))
    return "\n".join(lines) + ("\n" if lines else "")


def _variants_for(m):
    if not m["budget_enabled"]:
        return None
    budget = m["budget"]
    low = min(int(budget * 0.25), 1024)
    medium = int(budget * 0.5)
    high = budget
    return {
        level: {"options": {"thinking": {"type": "enabled", "budgetTokens": tokens}}}
        for level, tokens in (("low", low), ("medium", medium), ("high", high))
    }


def _model_entry(m):
    # Wire id (the 'id' field OpenCode sends to Bifrost) must be in
    # '<provider>/<model>' format for Bifrost routing: 'omlx/<model-id>'.
    if m["id"].startswith("omlx/"):
        wire_id = m["id"]
    elif m["id"].startswith("agw-"):
        wire_id = "omlx/" + m["id"][len("agw-"):]
    else:
        wire_id = "omlx/" + m["id"]
    entry = {
        "id": wire_id,
        "name": m["name"],
        "capabilities": {"vision": m["vision"]},
        "limit": {"context": m["context"], "output": m["output"]},
    }
    variants = _variants_for(m)
    if variants:
        entry["variants"] = variants
    return entry


def _config_key(m):
    """Config key (what the user sees in 'opencode models'). Prefixed with
    'bifrost-' to distinguish Bifrost-routed models from direct omlx models.
    The wire id (sent to Bifrost) is 'omlx/<model-id>' regardless."""
    if m["id"].startswith("bifrost-"):
        return m["id"]
    if m["id"].startswith("omlx/"):
        return "bifrost-" + m["id"][len("omlx/"):]
    if m["id"].startswith("agw-"):
        return "bifrost-" + m["id"][len("agw-"):]
    return "bifrost-" + m["id"]


def merge_config(models, provider_id, base_url, client_key,
                 mcp_url, mcp_key, mcp_name,
                 default_id, keep_stale, config_path):
    """Merge the gateway provider block into the existing opencode config.

    Returns {"config": <text>, "meta": {...}} mirroring the old heredoc's
    stdout contract.
    """
    if not models:
        raise ValueError("no models in manifest")

    provider = {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Bifrost",
        "options": {
            # Virtual client key validated by Bifrost's vk policy; the
            # gateway swaps it for the real omlx key upstream.
            # Falls back to a placeholder only when enforcement is not enabled.
            "baseURL": base_url,
            "apiKey": client_key or "bifrost",
        },
        # Config keys are prefixed with 'bifrost-' to distinguish from direct
        # omlx models. Wire ids (sent to Bifrost) are 'omlx/<model-id>'.
        "models": {_config_key(m): _model_entry(m) for m in models},
    }

    # Load the existing config (JSONC: // and /* */ comments, trailing commas).
    cfg = {}
    had_comments = False
    try:
        with open(config_path, encoding="utf-8") as fh:
            raw = fh.read()
        stripped, had_comments = jsonc.strip_comments(raw)
        cfg = json.loads(jsonc.strip_trailing_commas(stripped))
    except FileNotFoundError:
        pass
    except ValueError as e:
        raise ValueError(f"Failed to parse {config_path}: {e}")

    old_provider = cfg.get("provider", {}).get(provider_id, {})
    old_models = old_provider.get("models", {})
    new_ids = set(provider["models"])

    def is_stale(old_key):
        if old_key in new_ids:
            return False
        # Keys may have had different prefixes in older formats; strip known
        # prefixes and check if the resulting bifrost-prefixed key exists now.
        raw = old_key
        if raw.startswith("bifrost-"):
            raw = raw[len("bifrost-"):]
        elif raw.startswith("omlx/"):
            raw = raw[len("omlx/"):]
        elif raw.startswith("agw-"):
            raw = raw[len("agw-"):]
        return ("bifrost-" + raw) not in new_ids

    pruned = sorted(k for k in old_models if is_stale(k)) if old_models else []
    if pruned and keep_stale:
        for mid in pruned:
            provider["models"][mid] = old_models[mid]
        pruned = []

    # Merge: update/add provider.<id> and model; leave everything else untouched.
    cfg.setdefault("$schema", "https://opencode.ai/config.json")
    cfg.setdefault("provider", {})[provider_id] = provider
    # Default id is the raw omlx model id; convert to the bifrost-prefixed
    # config key.
    key = default_id
    if key.startswith("bifrost-"):
        key = key
    elif key.startswith("omlx/"):
        key = "bifrost-" + key[len("omlx/"):]
    elif key.startswith("agw-"):
        key = "bifrost-" + key[len("agw-"):]
    else:
        key = "bifrost-" + key
    suffix = "#low" if "variants" in provider["models"][key] else ""
    cfg["model"] = f"{provider_id}/{key}{suffix}"

    # MCP endpoint: Bifrost gateway, secured with the same virtual client key.
    # Merging preserves any other MCP servers the user has configured.
    if mcp_url and mcp_key:
        cfg.setdefault("mcp", {})[mcp_name] = {
            "type": "remote",
            "url": mcp_url,
            "headers": {
                "Authorization": f"Bearer {mcp_key}"
            },
        }

    out = json.dumps(cfg, indent=2) + "\n"
    return {
        "config": out,
        "meta": {"pruned": pruned, "had_comments": had_comments, "model": cfg["model"]},
    }


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        sys.exit("usage: python3 -m ldx.harness.opencode <current-default|build-manifest|merge>")
    cmd = argv[0]

    if cmd == "current-default":
        mid = current_default(os.environ["OPENCODE_CONFIG"],
                              os.environ.get("PROVIDER_ID", "local"))
        if mid:
            print(mid)
        return 0

    if cmd == "build-manifest":
        sys.stdout.write(build_manifest(
            sys.stdin.read().splitlines(),
            os.environ["OMLX_SETTINGS"],
            os.environ["OMLX_MODEL_SETTINGS"],
            os.environ["OMLX_MODELS_DIR"],
        ))
        return 0

    if cmd == "merge":
        with open(os.environ["MANIFEST"], encoding="utf-8") as fh:
            models = [json.loads(line) for line in fh if line.strip()]
        result = merge_config(
            models,
            provider_id=os.environ["PROVIDER_ID"],
            base_url=os.environ["GATEWAY_BASE_URL"],
            client_key=os.environ.get("CLIENT_KEY") or "",
            mcp_url=os.environ.get("MCP_URL") or "",
            mcp_key=os.environ.get("MCP_KEY") or "",
            mcp_name=os.environ.get("MCP_NAME", "bifrost"),
            default_id=os.environ["DEFAULT_ID"],
            keep_stale=os.environ.get("KEEP_STALE") == "true",
            config_path=os.environ["OPENCODE_CONFIG"],
        )
        print(json.dumps(result))
        return 0

    sys.exit(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    sys.exit(main())
