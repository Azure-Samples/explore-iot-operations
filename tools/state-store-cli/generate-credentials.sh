#!/bin/bash

mkdir certs

# create root CA
echo == Creating root CA ==
step certificate create --profile root-ca "my root ca" certs/root_ca.crt certs/root_ca.key

# create intermediate CA
echo == Creating intermediate CA ==
step certificate create --profile intermediate-ca "my intermediate ca" \
    certs/intermediate_ca.crt certs/intermediate_ca.key \
    --ca certs/root_ca.crt --ca-key certs/root_ca.key

# create client certificate
echo == Creating client certificate ==
step certificate create client \
    certs/client.crt certs/client.key \
    --not-after 8760h \
    --no-password --insecure \
    --ca certs/intermediate_ca.crt --ca-key certs/intermediate_ca.key

# create client trust bundle configmap used to validate x509 client connections
kubectl delete configmap client-ca-trust-bundle -n azure-iot-operations
kubectl create configmap client-ca-trust-bundle -n azure-iot-operations \
    --from-literal=client_ca.pem="$(cat certs/intermediate_ca.crt certs/root_ca.crt)"

# download the MQTT broker trust bundle
kubectl get secret azure-iot-operations-aio-ca-certificate \
    -n cert-manager \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > certs/broker-ca.crt
