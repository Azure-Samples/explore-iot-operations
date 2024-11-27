#!/bin/bash

# Enable debugging, exit on error, unset variables, and pipefail
set -euxo pipefail

echo "Starting On Create Command"

# Copy the custom first run notice over
sudo cp .devcontainer/welcome.txt /usr/local/etc/vscode-dev-containers/first-run-notice.txt

# Create k3d cluster and forwarded ports
k3d cluster delete
k3d cluster create \
-p '1883:1883@loadbalancer' \
-p '8883:8883@loadbalancer'

# Set the environment variables
echo '' >> ~/.bashrc
echo '# Set CODESPACES as false to avoid forced device code login' >> ~/.bashrc
echo 'export CODESPACES="FALSE"' >> ~/.bashrc
echo '# Set the cluster name based on the codespace name' >> ~/.bashrc
echo 'export CLUSTER_NAME=${CODESPACE_NAME%-*}' >> ~/.bashrc

echo "Ending On Create Command"
