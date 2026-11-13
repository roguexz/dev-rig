apiVersion: v1
kind: Service
metadata:
  name: postgres-host-access
  namespace: {{NAMESPACE}}
spec:
  type: NodePort
  selector:
    app.kubernetes.io/instance: postgresql
    app.kubernetes.io/name: postgresql
    app.kubernetes.io/component: primary
  ports:
    - port: 5432
      targetPort: 5432
      nodePort: 30432
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-lb
  namespace: {{NAMESPACE}}
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/instance: postgresql
    app.kubernetes.io/name: postgresql
    app.kubernetes.io/component: primary
  ports:
    - port: 5432
      targetPort: 5432
