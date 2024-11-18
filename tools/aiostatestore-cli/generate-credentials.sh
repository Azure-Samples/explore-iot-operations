#!/bin/bash

set -o errexit # fail if any command fails


# This script depends on certificates created for the AIO MQ Broker.
# These are the expected paths of the certificates and keys, please update according to your own path:
root_ca_cert="~/.step/certs/root_ca.crt"
intermediate_ca_cert="~/.step/certs/intermediate_ca.crt"
intermediate_ca_cert_key="~/.step/secrets/intermediate_ca_key"

# setup some variables
session_dir=$(dirname $(readlink -f $0))/../../.session
mkdir -p $session_dir

# install step
if [ ! $(which step) ]
then
    wget https://dl.smallstep.com/cli/docs-cli-install/latest/step-cli_amd64.deb -P /tmp
    sudo dpkg -i /tmp/step-cli_amd64.deb
fi

# Wait for CA trust bundle to be generated (for external connections to the MQTT Broker) and then push to a local file
kubectl wait --for=create --timeout=30s secret/azure-iot-operations-aio-ca-certificate -n cert-manager
kubectl get secret azure-iot-operations-aio-ca-certificate -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > $session_dir/broker-ca.crt

# create client certificate
step certificate create client $session_dir/client.crt $session_dir/client.key \
    -f \
    --not-after 8760h \
    --no-password \
    --insecure \
    --ca $intermediate_ca_cert \
    --ca-key $intermediate_ca_cert_key \
    --ca-password-file=$session_dir/password.txt

mkdir ~/aio_certs
cp $root_ca_cert  ~/aio_certs/
cp $session_dir/client.crt  ~/aio_certs
cp $session_dir/client.key  ~/aio_certs
