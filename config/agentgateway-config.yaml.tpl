# yaml-language-server: $schema=https://agentgateway.dev/schema/config
config:
  database:
    url: sqlite:///data/data.db
  # The config file is a read-only ConfigMap mount; the default 'file' mode
  # writes resource changes back into it and fails with
  # "failed to write to file /etc/agentgateway/config.yaml: Read-only file
  # system (os error 30)". 'hybrid' keeps this file as the baseline and
  # stores UI/API-managed resources in the SQLite database above.
  storage:
    mode: hybrid
  # Display a friendly name (email) instead of the OIDC subject (UUID).
  standardAttributes:
    user: "request.agent.claims.email"
gateways:
  default:
    port: 4000
ui:
  gateways: default
{{OIDC_SECTION}}
{{LLM_SECTION}}
routes:
- name: mcp-oauth-block
  # Block OAuth protected-resource metadata discovery. The harness does OAuth
  # discovery before using static headers; if it finds metadata (proxied from
  # an upstream OAuth server like Composio), it tries OAuth with cached tokens
  # instead of the configured Bearer header, failing with "Protected resource
  # X does not cover Y". Returning 404 forces the harness to use static auth.
  gateways:
  - default
  matches:
  - path:
      pathPrefix: /.well-known/oauth-protected-resource
  policies:
    directResponse:
      body: ""
      status: 404
- name: mcp
  gateways:
  - default
  matches:
  - path:
      pathPrefix: /mcp
  policies:
    apiKey:
      mode: strict
      keys:
      - key: ${{API_KEY_NAME}}
        metadata:
          user: local
  backends:
  - mcp:
{{MCP_TARGETS}}
