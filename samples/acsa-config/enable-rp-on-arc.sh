#!/bin/bash

RG=$(kubectl get connectedclusters -A -o json | jq -r '.items[0].spec.azureResourceId | split("/") | .[4]')

function howto_lookup {
  echo "Lookup the k8 bridge oid using this command:"
  echo "  az ad sp list --filter \"appId eq '319f651f-7ddb-4fc6-9857-7aef9250bd05'\" --query '[].id' -o tsv"
}

if [[ -z "$K8_BRIDGE" ]]; then
  echo "Error: K8_BRIDGE is not set in env."
  howto_lookup
  exit 1
fi

if [ -z "${RG}" ]; then
  echo "No Arc cluster found in current kube context"
fi

set -e

echo "Assigning acsa-rp-role to k8bridge (${K8_BRIDGE})"

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
  labels:
  name: k8bridge
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: acsa-rp-role
subjects:
  - kind: User
    name: "${K8_BRIDGE}"
    namespace: azure-arc
EOF
