#!/bin/bash

set -eu

POD_NAME="${POD_NAME:-auth-server-template}"

CA_CERT_NAME="${CA_CERT_NAME:-custom-auth-ca}"
CLIENT_CERT_NAME="${CLIENT_CERT_NAME:-custom-auth-client-cert}"
SERVER_CERT_NAME="${SERVER_CERT_NAME:-custom-auth-server-cert}"

root=$(readlink -m "$0/../..")
mkdir -p "$root/certs"
cd "$root/certs"

>extensions.conf cat <<-EOF
[ ca_cert ]
basicConstraints = critical, CA:TRUE
keyUsage = keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid

[ server_cert ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
subjectAltName=DNS:$POD_NAME

[ client_cert ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

openssl ecparam -name prime256v1 -genkey -noout -out "$CA_CERT_NAME-key.pem"
openssl req -new -key "$CA_CERT_NAME-key.pem" -subj "/CN=TestCA" -out "$CA_CERT_NAME-req.pem"
openssl x509 -req -in "$CA_CERT_NAME-req.pem" -signkey "$CA_CERT_NAME-key.pem" \
    -extfile extensions.conf -extensions ca_cert -out "$CA_CERT_NAME.pem" -days 3650
rm "$CA_CERT_NAME-req.pem"

kubectl create cm "$CA_CERT_NAME" --from-file="$CA_CERT_NAME"="$CA_CERT_NAME.pem"

openssl ecparam -name prime256v1 -genkey -noout -out "$SERVER_CERT_NAME-key.pem"
openssl req -new -key "$SERVER_CERT_NAME-key.pem" -subj "/CN=TestServer" -out "$SERVER_CERT_NAME-req.pem"
openssl x509 -req -in "$SERVER_CERT_NAME-req.pem" \
    -CA "$CA_CERT_NAME.pem" -CAkey "$CA_CERT_NAME-key.pem" -CAcreateserial \
    -extfile extensions.conf -extensions server_cert -out "$SERVER_CERT_NAME.pem" -days 3650
rm "$SERVER_CERT_NAME-req.pem"

cat "$CA_CERT_NAME.pem" >> "$SERVER_CERT_NAME.pem"
openssl verify -CAfile "$CA_CERT_NAME.pem" "$SERVER_CERT_NAME.pem"

kubectl create secret tls "$SERVER_CERT_NAME" \
  --cert="$SERVER_CERT_NAME.pem" \
  --key="$SERVER_CERT_NAME-key.pem"

openssl ecparam -name prime256v1 -genkey -noout -out "$CLIENT_CERT_NAME-key.pem"
openssl req -new -key "$CLIENT_CERT_NAME-key.pem" -subj "/CN=TestClientCert" -out "$CLIENT_CERT_NAME-req.pem"
openssl x509 -req -in "$CLIENT_CERT_NAME-req.pem" \
    -CA "$CA_CERT_NAME.pem" -CAkey "$CA_CERT_NAME-key.pem" -CAcreateserial \
    -extfile extensions.conf -extensions client_cert -out "$CLIENT_CERT_NAME.pem" -days 3650
rm "$CLIENT_CERT_NAME-req.pem"

cat "$CA_CERT_NAME.pem" >> "$CLIENT_CERT_NAME.pem"
openssl verify -CAfile "$CA_CERT_NAME.pem" "$CLIENT_CERT_NAME.pem"

kubectl create secret tls "$CLIENT_CERT_NAME" \
    --cert="$CLIENT_CERT_NAME.pem" \
    --key="$CLIENT_CERT_NAME-key.pem"
