apiVersion: v1
kind: Service
metadata:
  name: redis-host-access
  namespace: {{NAMESPACE}}
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: redis
  ports:
    - port: 6379
      targetPort: 6379
      nodePort: 30379
---
apiVersion: v1
kind: Service
metadata:
  name: redis-lb
  namespace: {{NAMESPACE}}
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: redis
  ports:
    - port: 6379
      targetPort: 6379
