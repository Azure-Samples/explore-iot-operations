# Create k3d cluster with local image registry
k3d registry delete registry.localhost
k3d cluster delete
k3d registry create registry.localhost --port 5500
k3d cluster create -p '1883:1883@loadbalancer' -p '8883:8883@loadbalancer' --registry-use k3d-registry.localhost:5500

# Deploy Broker
helm install broker --atomic oci://mqbuilds.azurecr.io/helm/aio-broker --version 0.7.0-nightly
kubectl apply -f ./broker.yaml 

# Deploy Operator helm chart

# Deploy ADR
helm install adrcommonprp --version 0.3.0 oci://azureadr.azurecr.io/helm/adr/common/adr-crds-prp


# Build HTTP server docker image
docker build -t http-server:latest ./SampleHttpServer
docker tag http-server:latest http-server:latest
k3d image import http-server:latest -c k3s-default

# Deploy HTTP server (as an asset)
kubectl apply -f ./SampleHttpServer/http-server.yaml
