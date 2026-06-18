#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

echo "Starting On Create Command"

# Copy the custom first run notice over.
sudo cp .devcontainer/welcome.txt /usr/local/etc/vscode-dev-containers/first-run-notice.txt

# Keep this script prebuild-safe. GitHub Codespaces prebuilds run onCreateCommand
# before snapshotting the filesystem, so don't start Docker/k3d workloads here.
# The k3d cluster is created lazily in postStartCommand.sh for real codespaces.

echo "Ending On Create Command"
