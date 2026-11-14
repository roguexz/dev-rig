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
# exclusion list as ldx-agentgateway sync-omlx, extended with embeddings.
_HELPER_PATTERNS = ("MarkItDown", "nomicai-modernbert", "*modernbert*",
                    "*embedding*", "*embed*")


def is_helper_model(model_id):
    return any(fnmatch.fnmatchcase(model_id, pat) for pat in _HELPER_PATTERNS)


def current_default(config_path, provider_id):
    """Model id (no provider prefix, no #variant, no agw- prefix) of the
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
    # Config keys carry the 'agw-' prefix; manifest ids don't.
    if mid.startswith("agw-"):
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
    # Wire id must match the gateway's model name (with 'agw-' prefix); the
    # gateway strips the prefix when forwarding to oMLX via params.model.
    wire_id = m["id"] if m["id"].startswith("agw-") else "agw-" + m["id"]
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


def merge_config(models, provider_id, base_url, mcp_url, client_key,
                 default_id, keep_stale, config_path):
    """Merge the gateway provider block into the existing opencode config.

    Returns {"config": <text>, "meta": {...}} mirroring the old heredoc's
    stdout contract.
    """
    if not models:
        raise ValueError("no models in manifest")

    provider = {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Local Server",
        "options": {
            # Virtual client key validated by the gateway's apiKey policy; the
            # gateway swaps it for the real omlx key ($OMLX_API_KEY) upstream.
            # Falls back to a placeholder only when enforcement is not enabled.
            "baseURL": base_url,
            "apiKey": client_key or "omlx",
        },
        # Config key and wire id both carry the 'agw-' prefix: the config key
        # avoids collisions with other providers' models in opencode's catalog,
        # and the wire id must match the gateway's model name for routing.
        "models": {("agw-" + m["id"] if not m["id"].startswith("agw-") else m["id"]): _model_entry(m) for m in models},
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
        # Keys gained the 'agw-' prefix at some point; don't report the rename as
        # a stale model when the prefixed twin exists now.
        return ("agw-" + old_key) not in new_ids

    pruned = sorted(k for k in old_models if is_stale(k)) if old_models else []
    if pruned and keep_stale:
        for mid in pruned:
            provider["models"][mid] = old_models[mid]
        pruned = []

    # Merge: update/add provider.<id> and model; leave everything else untouched.
    cfg.setdefault("$schema", "https://opencode.ai/config.json")
    cfg.setdefault("provider", {})[provider_id] = provider
    key = default_id if default_id.startswith("agw-") else "agw-" + default_id
    suffix = "#low" if "variants" in provider["models"][key] else ""
    cfg["model"] = f"{provider_id}/{key}{suffix}"

    # MCP endpoint: the gateway's /mcp path, secured with the same virtual key.
    # Merging preserves any other MCP servers the user has configured.
    cfg.setdefault("mcp", {})["agentgateway"] = {
        "type": "remote",
        "url": mcp_url,
        "headers": {
            "Authorization": f"Bearer {client_key}" if client_key else ""
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
            mcp_url=os.environ["MCP_URL"],
            client_key=os.environ.get("CLIENT_KEY") or "",
            default_id=os.environ["DEFAULT_ID"],
            keep_stale=os.environ.get("KEEP_STALE") == "true",
            config_path=os.environ["OPENCODE_CONFIG"],
        )
        print(json.dumps(result))
        return 0

    sys.exit(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    sys.exit(main())
