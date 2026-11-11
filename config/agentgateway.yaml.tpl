apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: agentgateway-data
  namespace: {{NAMESPACE}}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentgateway
  namespace: {{NAMESPACE}}
  labels:
    app: agentgateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: agentgateway
  template:
    metadata:
      labels:
        app: agentgateway
    spec:
      serviceAccountName: {{SERVICE_ACCOUNT}}
{{HOST_ALIASES}}
      securityContext:
        # Ensure the SQLite volume stays writable regardless of the image uid.
        fsGroup: 1000
      containers:
      - name: agentgateway
        image: {{AGENTGATEWAY_IMAGE}}
        imagePullPolicy: IfNotPresent
        securityContext:
          # Run as uid 1000 so the gateway can read the credential files
          # (perms 0400) written by the Vault Agent sidecar.
          runAsUser: 1000
        args:
        - "-f"
        - "/etc/agentgateway/config.yaml"
        envFrom:
        # Runtime credentials (OIDC cookie/client secret, oMLX API key); the
        # config file references them as $VAR and agentgateway expands them.
        - secretRef:
            name: {{AGENTGATEWAY_SECRET}}
            optional: true
        env:
        # CA bundle for verifying TLS certificates (Authelia, etc.).
        # The mkcert CA is distributed via a ClusterTrustBundle (created by
        # 'ldx certmanager install') and referenced via volume projection.
        - name: SSL_CERT_FILE
          value: "/etc/ssl/trust/ca-bundle.pem"
        - name: CURL_CA_BUNDLE
          value: "/etc/ssl/trust/ca-bundle.pem"
        ports:
        - containerPort: 4000
          name: http
        volumeMounts:
        - name: config
          mountPath: /etc/agentgateway/config.yaml
          subPath: config.yaml
        - name: data
          mountPath: /data
        # Shared credentials directory (written by the Vault Agent sidecar).
        - name: mcp-credentials
          mountPath: {{MCP_CREDENTIALS_DIR}}
          readOnly: true
        # mkcert CA bundle (from ClusterTrustBundle volume projection).
        - name: trust-bundle
          mountPath: /etc/ssl/trust
          readOnly: true
        # The admin port (15000) binds to the pod's loopback only, so probe
        # the gateway port instead.
        readinessProbe:
          tcpSocket:
            port: 4000
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 4000
          initialDelaySeconds: 15
          periodSeconds: 10
      - name: vault-agent
        image: {{VAULT_AGENT_IMAGE}}
        imagePullPolicy: IfNotPresent
        securityContext:
          # Run as uid 1000 so the credential files (perms 0400) are readable
          # by the gateway container (also uid 1000).
          runAsUser: 1000
        args:
        - "agent"
        - "-config=/etc/vault-agent/config/config.hcl"
        - "-log-level=info"
        volumeMounts:
        # Vault Agent config (auto-auth + templates).
        - name: vault-agent-config
          mountPath: /etc/vault-agent/config
        # Directory for the token file sink (and any other agent state).
        - name: vault-agent-state
          mountPath: /vault-agent
        # Shared credentials directory (read-write for the agent).
        - name: mcp-credentials
          mountPath: {{MCP_CREDENTIALS_DIR}}
        # The service account token (used by the kubernetes auth method).
        - name: vault-token
          mountPath: /var/run/secrets/kubernetes.io/serviceaccount
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: agentgateway-config
      - name: data
        persistentVolumeClaim:
          claimName: agentgateway-data
      - name: vault-agent-config
        configMap:
          name: {{VAULT_AGENT_CONFIG_CM}}
      # Shared emptyDir: Vault Agent writes credential files, gateway reads them.
      # fsGroup ensures the files are owned by uid 1000 (the gateway user).
      - name: mcp-credentials
        emptyDir: {}
      # emptyDir for the Vault Agent's token file and state.
      - name: vault-agent-state
        emptyDir: {}
      # mkcert CA bundle (from ClusterTrustBundle volume projection).
      - name: trust-bundle
        projected:
          sources:
          - clusterTrustBundle:
              name: mkcert-ca
              path: ca-bundle.pem
              optional: true
      # The pod's service account token (automatically mounted by Kubernetes,
      # but we mount it explicitly here for clarity).
      - name: vault-token
        projected:
          sources:
          - serviceAccountToken:
              path: token
              expirationSeconds: 3600
              audience: vault
---
apiVersion: v1
kind: Service
metadata:
  name: agentgateway
  namespace: {{NAMESPACE}}
spec:
  type: ClusterIP
  selector:
    app: agentgateway
  ports:
  - port: 4000
    targetPort: 4000
    name: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: agentgateway
  namespace: {{NAMESPACE}}
spec:
  ingressClassName: traefik
  rules:
  - host: {{AGENTGATEWAY_HOST}}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: agentgateway
            port:
              number: 4000
