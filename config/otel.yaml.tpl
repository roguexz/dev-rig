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
        # Extra CA certificates (mkcert CA for local services like Authelia).
        # Mounted as SSL_CERT_DIR so they're added to the system root store.
        - name: SSL_CERT_DIR
          value: "/etc/ssl/extra-cas"
{{OIDC_ENV}}
        ports:
        - containerPort: 3000
          name: grafana
        - containerPort: 4317
          name: otlp-grpc
        - containerPort: 4318
          name: otlp-http
        volumeMounts:
        # Extra CA certificates (mkcert CA) mounted as a directory for SSL_CERT_DIR.
        - name: extra-cas
          mountPath: /etc/ssl/extra-cas
          readOnly: true
      volumes:
      - name: extra-cas
        configMap:
          name: extra-cas
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
