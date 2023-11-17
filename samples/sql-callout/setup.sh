# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Create manifest file.
cat << EOF > manifest.yml
---
kind: PersistentVolume
apiVersion: v1
metadata:
  namespace: $1
  name: pg-pv
  labels:
    app: postgres
    type: local
spec:
  storageClassName: manual
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/mnt/data"
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  namespace: $1
  name: pg-pvc
  labels:
    app: postgres
spec:
  storageClassName: manual
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: $1
  name: pg-config
  labels:
    app: postgres
data:
  POSTGRES_DB: $2
  POSTGRES_USER: $3
  POSTGRES_PASSWORD: $4
---
apiVersion: v1
kind: Service
metadata:
  namespace: $1
  name: pg-svc
  labels:
    app: postgres
spec:
  ports:
  - port: 5432
    name: postgres
  type: NodePort 
  selector:
    app: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  namespace: $1
  name: pg-statefulset
  labels:
    app: postgres
spec:
  serviceName: "postgres"
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: mcr.microsoft.com/cbl-mariner/base/postgres:14
        envFrom:
        - configMapRef:
            name: pg-config
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: pv-data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: pv-data
        persistentVolumeClaim:
          claimName: pg-pvc
EOF

# Delete resources from kubernetes if one already exists.
kubectl delete -f manifest.yml

# Apply newly created kubernetes manifest.
kubectl apply -f manifest.yml

# Wait for sql pod to be ready.
kubectl wait --for=condition=ready --namespace $1 pod/pg-statefulset-0

# Cat contents of SQL script into psql exec on new SQL pod.
cat $5 | kubectl exec -it --namespace $1 pg-statefulset-0 -- psql postgresql://$3:$4@localhost:5432/$2

