# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy src files into container
COPY . ./

# Download dependencies
RUN go mod download

# Build the application
RUN go build -v -o /bin/app .

FROM alpine:latest

COPY --from=builder /bin/app /app

CMD ["/app"]