#!/usr/bin/env bash

if [ -z "$1" ]; then
  read -sp "Enter your password: " PASSWORD
  echo
else
  PASSWORD="$1"
fi

ITERATIONS=100000
KEYLEN=64
SALT_SIZE=16

SALT_HEX=$(openssl rand -hex "$SALT_SIZE")
SALT_B64=$(echo "$SALT_HEX" | xxd -r -p | openssl base64 -A | tr -d '=')
PASSWORD_HEX=$(echo -n "$PASSWORD" | xxd -p)

DK_HEX=$(
  openssl kdf \
    -keylen $KEYLEN \
    -kdfopt hexpass:"$PASSWORD_HEX" \
    -kdfopt digest:sha512 \
    -kdfopt hexsalt:"$SALT_HEX" \
    -kdfopt iter:$ITERATIONS \
    PBKDF2
)
DK_B64=$(
  echo "$DK_HEX" | xxd -r -p | openssl base64 -A | tr -d '='
)

echo "\$pbkdf2-sha512\$i=${ITERATIONS},l=${KEYLEN}\$${SALT_B64}\$${DK_B64}"
