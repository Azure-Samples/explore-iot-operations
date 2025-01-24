FROM alpine:3.21

RUN apk upgrade --no-cache && \
    apk add --no-cache libgcc

COPY auth-server-user-pass-mqtt /bin/auth-server-user-pass-mqtt

# TODO: env var validation should return all missing vars in one go
ENTRYPOINT \
    if [ -z "$SERVER_CERT_CHAIN" ]; then echo "SERVER_CERT_CHAIN must be set"; exit 1; fi; \
    if [ -z "$SERVER_CERT_KEY" ]; then echo "SERVER_CERT_KEY must be set"; exit 1; fi; \
    if [ -z "$STORED_CREDENTIALS_FILE" ]; then echo "STORED_CREDENTIALS_FILE must be set"; exit 1; fi;\
    /bin/auth-server-user-pass-mqtt -p 443 -c "$SERVER_CERT_CHAIN" -k "$SERVER_CERT_KEY" -s "$STORED_CREDENTIALS_FILE";