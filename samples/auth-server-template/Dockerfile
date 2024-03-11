FROM alpine:3.19

RUN apk upgrade --no-cache && \
    apk add --no-cache libgcc

COPY auth-server-template /bin/auth-server-template

ENTRYPOINT if [ -z "$SERVER_CERT_CHAIN" ]; then echo "SERVER_CERT_CHAIN must be set"; exit 1; fi; \
    if [ -z "$SERVER_CERT_KEY" ]; then echo "SERVER_CERT_KEY must be set"; exit 1; fi; \
    if [ -z "$CLIENT_CERT_ISSUER" ]; \
    then /bin/auth-server-template -p 443 -c "$SERVER_CERT_CHAIN" -k "$SERVER_CERT_KEY"; \
    else /bin/auth-server-template -p 443 -c "$SERVER_CERT_CHAIN" -k "$SERVER_CERT_KEY" -i "$CLIENT_CERT_ISSUER"; \
    fi
