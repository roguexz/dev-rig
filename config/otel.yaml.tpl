apiVersion: apps/v1
kind: Deployment
metadata:
  name: lgtm
  namespace: {{NAMESPACE}}
  labels:
    app: lgtm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lgtm
  template:
    metadata:
      labels:
        app: lgtm
    spec:
      containers:
      - name: lgtm
        image: grafana/otel-lgtm:latest
        env:
        # Override the default Grafana admin password
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "changeit"
        # CA bundle for verifying TLS certificates (Authelia, etc.).
        # The mkcert CA is distributed via a ClusterTrustBundle (created by
        # 'ldx certmanager install') and referenced via volume projection.
        - name: SSL_CERT_FILE
          value: "/etc/ssl/trust/ca-bundle.pem"
        - name: CURL_CA_BUNDLE
          value: "/etc/ssl/trust/ca-bundle.pem"
{{OIDC_ENV}}
        ports:
        - containerPort: 3000
          name: grafana
        - containerPort: 4317
          name: otlp-grpc
        - containerPort: 4318
          name: otlp-http
        volumeMounts:
        # mkcert CA bundle (from ClusterTrustBundle volume projection).
        - name: trust-bundle
          mountPath: /etc/ssl/trust
          readOnly: true
      volumes:
      - name: trust-bundle
        projected:
          sources:
          - clusterTrustBundle:
              name: mkcert-ca
              path: ca-bundle.pem
              optional: true
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: {{NAMESPACE}}
spec:
  type: ClusterIP
  selector:
    app: lgtm
  ports:
  - port: 80
    targetPort: 3000
    name: http
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: {{NAMESPACE}}
spec:
  type: LoadBalancer
  selector:
    app: lgtm
  ports:
  - port: 4317
    targetPort: 4317
    name: grpc
  - port: 4318
    targetPort: 4318
    name: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: {{NAMESPACE}}
spec:
  ingressClassName: traefik
  rules:
  - host: otel.rd.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 80
