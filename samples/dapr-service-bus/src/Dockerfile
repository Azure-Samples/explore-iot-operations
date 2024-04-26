# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy dependencies
COPY go.mod go.sum main.go ./

# Download dependencies
RUN go mod download

# Build the application
RUN go build -v -o /bin/app .

FROM alpine:latest

COPY --from=builder /bin/app /app

CMD ["/app"]