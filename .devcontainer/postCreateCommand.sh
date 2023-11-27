#!/bin/sh

set -o errexit
set -o nounset
set -o pipefail

echo "Starting Post Create Command"

# This env var is important to allow k3s to support shared mounts, required for CSI driver
# Temporary fix until made default https://github.com/k3d-io/k3d/pull/1268#issuecomment-1745466499
export K3D_FIX_MOUNTS=1

# Create k3d cluster with NFS support and forwarded ports
# See https://github.com/jlian/k3d-nfs
k3d cluster create -i ghcr.io/jlian/k3d-nfs:v1.25.3-k3s1 \
-p '1883:1883@loadbalancer' \
-p '8883:8883@loadbalancer' \
-p '6001:6001@loadbalancer' \
-p '4000:80@loadbalancer'

echo "Ending Post Create Command"
