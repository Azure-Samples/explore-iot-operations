FROM alpine:3.21

RUN apk upgrade --no-cache && \
    apk add --no-cache libgcc

COPY auth-server-user-pass-mqtt /bin/auth-server-user-pass-mqtt

ENTRYPOINT \
    MISSING_VARS=""; \
    if [ -z "$SERVER_CERT_CHAIN" ]; then MISSING_VARS="$MISSING_VARS SERVER_CERT_CHAIN"; fi; \
    if [ -z "$SERVER_CERT_KEY" ]; then MISSING_VARS="$MISSING_VARS SERVER_CERT_KEY"; fi; \
    if [ -z "$STORED_CREDENTIALS_FILE" ]; then MISSING_VARS="$MISSING_VARS STORED_CREDENTIALS_FILE"; fi; \
    if [ -n "$MISSING_VARS" ]; then echo "Missing environment variables:$MISSING_VARS"; exit 1; fi; \
    /bin/auth-server-user-pass-mqtt -p 443 -c "$SERVER_CERT_CHAIN" -k "$SERVER_CERT_KEY" -s "$STORED_CREDENTIALS_FILE";