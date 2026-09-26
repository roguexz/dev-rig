# LiteLLM Proxy (`ldx litellm`)

This command deploys a LiteLLM proxy instance in the Kubernetes cluster backed by the PostgreSQL database deployment and
exposes it so that it is accessible directly from your host machine and from pods inside the cluster.

## Commands

### `ldx litellm install`

This command installs LiteLLM proxy into the `commons` namespace:

1. **Database Check & Initialization**: Verifies PostgreSQL is running and automatically creates the `litellm` database
   if it does not already exist.
2. **LiteLLM Deployment**: Deploys the LiteLLM proxy image (`ghcr.io/berriai/litellm:main-latest`) connected to
   PostgreSQL (`DATABASE_URL=postgresql://postgres:changeit@postgresql.commons.svc.cluster.local:5432/litellm`).
3. **Master Key Configuration**: Sets the admin master key `LITELLM_MASTER_KEY` to `sk-changeit` and enables database
   model storage (`STORE_MODEL_IN_DB=True`).
4. **Service & Ingress Exposure**: Exposes the proxy via Traefik Ingress (`https://litellm.rd.localhost`),
   LoadBalancer/NodePort (`localhost:4000`), and internal ClusterIP.

### `ldx litellm uninstall`

This command cleans up the LiteLLM deployment, services, and ingress, leaving the `commons` namespace and PostgreSQL
database intact.

## Connecting to LiteLLM Proxy

### From the Host Machine

For applications running directly on your host OS or accessing the LiteLLM Admin UI:

- **HTTPS URL (Ingress):** `https://litellm.rd.localhost`
- **HTTP URL (Direct/Host):** `http://localhost:4000` (or via NodePort `30400`)
- **Admin Master Key:** `sk-changeit`

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name
to connect:

- **Endpoint:** `http://litellm.commons.svc.cluster.local:4000`
- **Admin Master Key:** `sk-changeit`
