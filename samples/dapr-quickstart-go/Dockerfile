# syntax=docker/dockerfile:1

## Build
FROM golang:1.21-bullseye AS build
WORKDIR /work
COPY main.go .
COPY go.mod .
COPY go.sum .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o .

## Deploy
FROM alpine:3.18
WORKDIR /
COPY --from=build work/dapr-quickstart-go /dapr-quickstart-go
EXPOSE 6001
ENTRYPOINT ["/dapr-quickstart-go"]