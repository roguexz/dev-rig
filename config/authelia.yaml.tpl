apiVersion: v1
kind: ConfigMap
metadata:
  name: authelia-users
  namespace: {{NAMESPACE}}
data:
  users_database.yml: |
    users:
      admin:
        disabled: false
        displayname: "Cluster Admin"
        password: "{{PASSWORD_HASH}}"
        email: "admin@rd.localhost"
        groups:
          - admins
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: authelia-config
  namespace: {{NAMESPACE}}
data:
  configuration.yml: |
    theme: 'dark'

    server:
      address: 'tcp://:{{AUTHELIA_PORT}}/'
      tls:
        key: '/config/tls/tls.key'
        certificate: '/config/tls/tls.crt'
      buffers:
        read: 4096
        write: 4096
      endpoints:
        enable_pprof: false
        enable_expvars: false

    log:
      level: 'info'
      format: 'text'

    webauthn:
      disable: false
      display_name: 'Local K8s Cluster'
      enable_passkey_login: true

    authentication_backend:
      file:
        path: '/config/users/users_database.yml'
        watch: true

    session:
      cookies:
        - domain: 'rd.localhost'
          authelia_url: 'https://{{AUTHELIA_HOST}}/'
          same_site: 'lax'
          inactivity: '1h'
          expiration: '1h'
          remember_me: '1M'
        - domain: 'cluster.local'
          authelia_url: 'https://authelia.{{NAMESPACE}}.svc.cluster.local/'
          same_site: 'lax'
          inactivity: '1h'
          expiration: '1h'
          remember_me: '1M'

    regulation:
      max_retries: 5
      find_time: '2m'
      ban_time: '5m'

    storage:
      local:
        path: '/data/db.sqlite3'

    notifier:
      filesystem:
        filename: '/data/notification.txt'

    access_control:
      default_policy: 'two_factor'
      rules:
        - domain: ['{{AUTHELIA_HOST}}']
          policy: 'bypass'
        - domain: ['vault.rd.localhost']
          policy: 'two_factor'
        - domain: ['agentgateway.rd.localhost']
          policy: 'two_factor'
        - domain: ['otel.rd.localhost']
          policy: 'two_factor'

    identity_providers:
      oidc:
        enforce_pkce: 'public_clients_only'
        cors:
          endpoints:
            - 'authorization'
            - 'token'
            - 'revocation'
            - 'introspection'
          allowed_origins_from_client_redirect_uris: true
        jwks:
          - key_id: 'local-k8s-key'
            algorithm: 'RS256'
            use: 'sig'
            key: |
{{JWKS_KEY}}
        clients:
          - client_id: 'vault'
            client_name: 'HashiCorp Vault'
            client_secret: '{{VAULT_SECRET_HASH}}'
            public: false
            authorization_policy: 'one_factor'
            redirect_uris:
              - 'https://vault.rd.localhost/ui/vault/auth/oidc/oidc/callback'
              - 'http://localhost:8250/oidc/callback'
            scopes:
              - 'openid'
              - 'profile'
              - 'email'
              - 'groups'

          - client_id: 'agentgateway'
            client_name: 'agentgateway'
            client_secret: '{{AGENTGATEWAY_SECRET_HASH}}'
            public: false
            authorization_policy: 'one_factor'
            redirect_uris:
              - 'https://agentgateway.rd.localhost/oauth/callback'
            scopes:
              - 'openid'
              - 'profile'
              - 'email'
              - 'groups'

          - client_id: 'grafana'
            client_name: 'Grafana'
            client_secret: '{{GRAFANA_SECRET_HASH}}'
            public: false
            authorization_policy: 'one_factor'
            redirect_uris:
              - 'https://otel.rd.localhost/login/generic_oauth'
            scopes:
              - 'openid'
              - 'profile'
              - 'email'
              - 'groups'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: authelia-data
  namespace: {{NAMESPACE}}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: authelia-cert
  namespace: {{NAMESPACE}}
spec:
  secretName: authelia-cert
  dnsNames:
    - {{AUTHELIA_HOST}}
    - authelia.{{NAMESPACE}}.svc.cluster.local
    - authelia
  issuerRef:
    name: mkcert-issuer
    kind: ClusterIssuer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authelia
  namespace: {{NAMESPACE}}
  labels:
    app.kubernetes.io/name: authelia
spec:
  replicas: 1
  strategy:
    type: Recreate  # Required for SQLite lock safety
  selector:
    matchLabels:
      app.kubernetes.io/name: authelia
  template:
    metadata:
      labels:
        app.kubernetes.io/name: authelia
    spec:
      enableServiceLinks: false  # Prevents env variable naming conflicts
      containers:
        - name: authelia
          image: {{AUTHELIA_IMAGE}}
          imagePullPolicy: IfNotPresent
          ports:
            - name: https
              containerPort: {{AUTHELIA_PORT}}
              protocol: TCP
          env:
            - name: AUTHELIA_JWT_SECRET_FILE
              value: "/config/secrets/JWT_SECRET"
            - name: AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE
              value: "/config/secrets/STORAGE_KEY"
            - name: AUTHELIA_SESSION_SECRET_FILE
              value: "/config/secrets/SESSION_SECRET"
            - name: AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE
              value: "/config/secrets/OIDC_HMAC_SECRET"
          volumeMounts:
            - name: config
              mountPath: /config/configuration.yml
              subPath: configuration.yml
            - name: users
              mountPath: /config/users/users_database.yml
              subPath: users_database.yml
            - name: secrets
              mountPath: /config/secrets
            - name: data
              mountPath: /data
            - name: tls
              mountPath: /config/tls
              readOnly: true
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - wget --no-check-certificate -qO- https://127.0.0.1:{{AUTHELIA_PORT}}/api/health
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - wget --no-check-certificate -qO- https://127.0.0.1:{{AUTHELIA_PORT}}/api/health
            initialDelaySeconds: 15
            periodSeconds: 15
      volumes:
        - name: config
          configMap:
            name: authelia-config
        - name: users
          configMap:
            name: authelia-users
        - name: secrets
          secret:
            secretName: authelia-secrets
        - name: data
          persistentVolumeClaim:
            claimName: authelia-data
        - name: tls
          secret:
            secretName: authelia-cert
---
apiVersion: v1
kind: Service
metadata:
  name: authelia
  namespace: {{NAMESPACE}}
{{SERVICE_ANNOTATIONS}}
spec:
  type: ClusterIP
  ports:
    - name: https
      port: {{AUTHELIA_PORT}}
      targetPort: https
  selector:
    app.kubernetes.io/name: authelia
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: authelia
  namespace: {{NAMESPACE}}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  rules:
    - host: {{AUTHELIA_HOST}}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: authelia
                port:
                  number: {{AUTHELIA_PORT}}
