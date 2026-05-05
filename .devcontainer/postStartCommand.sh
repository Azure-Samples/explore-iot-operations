#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

BASHRC="${HOME}/.bashrc"
touch "${BASHRC}"

# Keep the helper environment exports idempotent across codespace restarts.
grep -qxF 'export CODESPACES="FALSE"' "${BASHRC}" || echo 'export CODESPACES="FALSE"' >> "${BASHRC}"
grep -qxF 'export CLUSTER_NAME=${CODESPACE_NAME%-*}-codespace' "${BASHRC}" || echo 'export CLUSTER_NAME=${CODESPACE_NAME%-*}-codespace' >> "${BASHRC}"

export CODESPACES="FALSE"
if [[ -n "${CODESPACE_NAME:-}" ]]; then
  export CLUSTER_NAME="${CODESPACE_NAME%-*}-codespace"
else
  export CLUSTER_NAME="${CLUSTER_NAME:-k3s-default}"
fi

printf 'Environment:\nSUBSCRIPTION_ID: %s\nRESOURCE_GROUP: %s\nLOCATION: %s\nCLUSTER_NAME: %s\n' \
  "${SUBSCRIPTION_ID:-}" \
  "${RESOURCE_GROUP:-}" \
  "${LOCATION:-}" \
  "${CLUSTER_NAME}"

if [[ "${SKIP_K3D_CLUSTER_CREATE:-}" == "1" ]]; then
  echo "Skipping k3d cluster creation because SKIP_K3D_CLUSTER_CREATE=1."
  exit 0
fi

if k3d cluster list -o json 2>/dev/null | grep -q '"name"[[:space:]]*:[[:space:]]*"k3s-default"'; then
  echo "k3d cluster 'k3s-default' already exists."
else
  echo "Creating k3d cluster 'k3s-default'."
  k3d cluster create \
    -p '1883:1883@loadbalancer' \
    -p '8883:8883@loadbalancer'
fi
