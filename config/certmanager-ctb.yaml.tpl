apiVersion: {{API_VERSION}}
kind: ClusterTrustBundle
metadata:
  name: mkcert-ca
spec:
  trustBundle: |
{{CA_PEM}}
