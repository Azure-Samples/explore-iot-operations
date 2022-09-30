#!/bin/bash

POD_NAME="${POD_NAME:-auth-server-template}"

CA_CERT_NAME="${CA_CERT_NAME:-custom-auth-ca}"
CLIENT_CERT_NAME="${CLIENT_CERT_NAME:-custom-auth-client-cert}"
SERVER_CERT_NAME="${SERVER_CERT_NAME:-custom-auth-server-cert}"

kubectl delete cm --ignore-not-found=true "$CA_CERT_NAME"
kubectl delete secret --ignore-not-found=true "$SERVER_CERT_NAME" "$CLIENT_CERT_NAME"
