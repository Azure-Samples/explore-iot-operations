sudo apt-get update

# Install k3d
wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Install helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install .NET 8.0
sudo apt-get install -y dotnet-sdk-8.0

# Create k3d cluster with local image registry

# Deploy Operator helm chart

# Deploy HTTP server (as an asset)
