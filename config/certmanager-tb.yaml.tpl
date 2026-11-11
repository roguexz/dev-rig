apiVersion: {{API_VERSION}}
kind: TrustBundle
metadata:
  name: mkcert-ca
  namespace: cert-manager
spec:
  secretName: mkcert-root-ca
  secretKey: tls.crt
