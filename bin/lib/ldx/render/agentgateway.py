"""agentgateway config assembly (ported from bin/commands/agentgateway/common.sh).

The bash side collects the raw materials with kubectl (models/providers
fragments from the ConfigMap, OIDC wiring from the Secret, MCP targets from
the gateway admin API) and pipes a JSON spec to:

    python3 -m ldx.render.agentgateway config --template config/agentgateway-config.yaml.tpl

and streams tool names to:

    python3 -m ldx.render.agentgateway vault-agent --outdir DIR \
        --vault-ns NS --role ROLE --creds-dir DIR

Text semantics match the old bash helpers exactly: {{VAR}} tokens are
replaced anywhere in a line (render_template), and a line consisting solely
of a marker ({{OIDC_SECTION}} etc.) is replaced by the section content,
or removed when the section is empty (inject_block).
"""

import argparse
import json
import os
import sys


def inject(text, marker, content):
    """Replace the line equal to `marker` with `content`; drop it if empty."""
    out = []
    for line in text.split("\n"):
        if line == marker:
            if content:
                out.extend(content.rstrip("\n").split("\n"))
            continue
        out.append(line)
    return "\n".join(out)


def render_config(template, spec):
    """Assemble the gateway config.yaml from the template and the spec dict."""
    oidc = spec.get("oidc")
    oidc_section = ""
    if oidc:
        host = spec["authelia_host"]
        oidc_section = f"""  policies:
    oidc:
      issuer: https://{host}
      authorizationEndpoint: https://{host}/api/oidc/authorization
      tokenEndpoint: https://{host}/api/oidc/token
      jwks:
        url: https://{host}/jwks.json
      clientId: {oidc["client_id"]}
      clientSecret: $UI_CLIENT_SECRET
      redirectURI: https://{spec['gateway_host']}/oauth/callback
      # Ask Authelia for standard scopes so the UI shows name/email.
      scopes:
      - openid
      - profile
      - email
      - groups
"""

    # LLM routes are always authenticated with virtual client keys, even when
    # no models are synced. This makes the auth model consistent with MCP
    # routes and gives harnesses a clear 401 instead of a 404 when hitting
    # /v1 before models are available.
    providers_line = spec.get("providers_fragment") or "  providers: []"
    models_line = spec.get("models_fragment") or "  models: []"

    # Virtual client keys: inbound requests must carry one of these in
    # 'Authorization: Bearer <key>'; the gateway swaps in the provider
    # key ($OMLX_API_KEY) before forwarding. The raw key stays in the
    # Secret; the config references it for env expansion.
    llm_section = f"""llm:
  gateways:
  - default
{providers_line}
  policies:
    apiKey:
      mode: strict
      keys:
      - key: ${spec['api_key_name']}
        metadata:
          user: local
          name: Local Access
{models_line}
"""

    # The MCP route always uses the same virtual client key; registered
    # targets (from the gateway database) are listed explicitly because
    # hybrid storage mode does not merge file routes with DB targets. The
    # spec carries the raw target entries (each "      - name: ..."); the
    # list header is added here.
    raw_targets = (spec.get("targets_yaml") or "").strip("\n")
    if raw_targets:
        targets_yaml = "      targets:\n" + raw_targets
    else:
        targets_yaml = "      targets: []"

    rendered = template.replace("{{API_KEY_NAME}}", spec["api_key_name"])
    rendered = inject(rendered, "{{OIDC_SECTION}}", oidc_section)
    rendered = inject(rendered, "{{LLM_SECTION}}", llm_section)
    rendered = inject(rendered, "{{MCP_TARGETS}}", targets_yaml)
    return rendered


def render_vault_agent(vault_ns, role, creds_dir, tools):
    """Vault Agent files: config.hcl plus one Go template per tool."""
    config = f"""# Vault Agent auto-auth + template config
vault {{
  address = "http://vault.{vault_ns}.svc.cluster.local:8200"
}}

auto_auth {{
  method "kubernetes" {{
    config {{
      role = "{role}"
      kubernetes_host = "https://kubernetes.default.svc:443"
    }}
  }}
  sink "file" {{
    config {{
      path = "/vault-agent/token"
    }}
  }}
}}
"""
    files = {"config.hcl": config}
    for tool in tools:
        tool = tool.strip()
        if not tool:
            continue
        config += f"""
template {{
  source = "/etc/vault-agent/config/template-{tool}.go.tpl"
  destination = "{creds_dir}/{tool}.token"
  perms = "0400"
}}
"""
        # Output just the token value without any trailing newline.
        # In KV v2, the secret response has data.data.token.
        files[f"template-{tool}.go.tpl"] = (
            '{{- with secret "secret/data/mcp/' + tool + '" }}'
            '{{ .Data.data.token }}{{- end }}\n'
        )
    files["config.hcl"] = config
    return files


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        sys.exit("usage: python3 -m ldx.render.agentgateway <config|vault-agent> ...")

    if argv[0] == "config":
        ap = argparse.ArgumentParser(prog="ldx.render.agentgateway config")
        ap.add_argument("--template", required=True)
        args = ap.parse_args(argv[1:])
        with open(args.template, encoding="utf-8") as fh:
            template = fh.read()
        spec = json.load(sys.stdin)
        sys.stdout.write(render_config(template, spec))
        return 0

    if argv[0] == "vault-agent":
        ap = argparse.ArgumentParser(prog="ldx.render.agentgateway vault-agent")
        ap.add_argument("--outdir", required=True)
        ap.add_argument("--vault-ns", required=True)
        ap.add_argument("--role", required=True)
        ap.add_argument("--creds-dir", required=True)
        args = ap.parse_args(argv[1:])
        files = render_vault_agent(args.vault_ns, args.role, args.creds_dir,
                                   sys.stdin.read().splitlines())
        os.makedirs(args.outdir, exist_ok=True)
        for name, content in files.items():
            with open(os.path.join(args.outdir, name), "w", encoding="utf-8") as fh:
                fh.write(content)
        return 0

    sys.exit(f"unknown subcommand: {argv[0]}")


if __name__ == "__main__":
    sys.exit(main())
