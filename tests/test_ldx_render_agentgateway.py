"""Unit tests for ldx.render.agentgateway (pure; no cluster, no network)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin" / "lib"))

from ldx.render import agentgateway  # noqa: E402

# Mirrors config/agentgateway-config.yaml.tpl's injection points.
TEMPLATE = """config:
  database:
    url: sqlite:///data/data.db
{{OIDC_SECTION}}
{{LLM_SECTION}}
mcp:
  gateways:
  - default
  routes:
  - path: /mcp
    backend:
      mcp:
{{MCP_TARGETS}}
      - key: ${{API_KEY_NAME}}
"""


def spec(**over):
    base = {
        "authelia_host": "auth.rd.localhost",
        "gateway_host": "agentgateway.rd.localhost",
        "api_key_name": "AGENTGATEWAY_API_KEY",
        "oidc": None,
        "models_fragment": "",
        "providers_fragment": "",
        "targets_yaml": "",
    }
    base.update(over)
    return base


class Inject(unittest.TestCase):
    def test_marker_replaced(self):
        out = agentgateway.inject("a\n{{M}}\nb", "{{M}}", "X\nY")
        self.assertEqual(out, "a\nX\nY\nb")

    def test_empty_marker_dropped(self):
        out = agentgateway.inject("a\n{{M}}\nb", "{{M}}", "")
        self.assertEqual(out, "a\nb")

    def test_trailing_newline_not_doubled(self):
        out = agentgateway.inject("a\n{{M}}\nb", "{{M}}", "X\n")
        self.assertEqual(out, "a\nX\nb")


class RenderConfig(unittest.TestCase):
    def test_minimal_no_oidc_no_models(self):
        out = agentgateway.render_config(TEMPLATE, spec())
        self.assertNotIn("oidc:", out)
        self.assertNotIn("{{", out)
        self.assertIn("  providers: []", out)
        self.assertIn("  models: []", out)
        self.assertIn("      targets: []", out)
        self.assertIn("- key: $AGENTGATEWAY_API_KEY", out)

    def test_oidc_on(self):
        out = agentgateway.render_config(
            TEMPLATE, spec(oidc={"client_id": "agentgateway"}))
        self.assertIn("issuer: https://auth.rd.localhost", out)
        self.assertIn("clientId: agentgateway", out)
        self.assertIn("clientSecret: $UI_CLIENT_SECRET", out)
        self.assertIn("redirectURI: https://agentgateway.rd.localhost/oauth/callback", out)

    def test_targets_wrapped_with_header(self):
        out = agentgateway.render_config(
            TEMPLATE, spec(targets_yaml="      - name: composio\n        mcp:\n          host: x"))
        self.assertIn("      targets:\n      - name: composio", out)

    def test_fragments_inserted_verbatim(self):
        out = agentgateway.render_config(
            TEMPLATE,
            spec(models_fragment='  models:\n  - name: "agw-a"',
                 providers_fragment="  providers:\n  - name: omlx"))
        self.assertIn('  - name: "agw-a"', out)
        self.assertIn("  - name: omlx", out)
        # models go after the policies block, providers after 'gateways'
        self.assertLess(out.index("- name: omlx"), out.index("policies:"))
        self.assertLess(out.index("policies:"), out.index('  - name: "agw-a"'))


class RenderVaultAgent(unittest.TestCase):
    def test_no_tools(self):
        files = agentgateway.render_vault_agent("commons", "agentgateway-mcp",
                                                "/etc/agentgateway/mcp-credentials", [])
        self.assertEqual(list(files), ["config.hcl"])
        self.assertIn('address = "http://vault.commons.svc.cluster.local:8200"', files["config.hcl"])
        self.assertIn('role = "agentgateway-mcp"', files["config.hcl"])
        self.assertNotIn("template {", files["config.hcl"])

    def test_per_tool_files(self):
        files = agentgateway.render_vault_agent("commons", "role", "/cred",
                                                ["composio", "other"])
        self.assertEqual(sorted(files),
                         ["config.hcl", "template-composio.go.tpl", "template-other.go.tpl"])
        self.assertIn('destination = "/cred/composio.token"', files["config.hcl"])
        self.assertIn('perms = "0400"', files["config.hcl"])
        self.assertEqual(
            files["template-composio.go.tpl"],
            '{{- with secret "secret/data/mcp/composio" }}{{ .Data.data.token }}{{- end }}\n')


if __name__ == "__main__":
    unittest.main()
