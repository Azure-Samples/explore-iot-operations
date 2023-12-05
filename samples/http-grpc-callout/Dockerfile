# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/oss/go/microsoft/golang:1.21-cbl-mariner2.0 AS build
LABEL org.opencontainers.image.source=https://github.com/Azure-Samples/explore-iot-operations
LABEL org.opencontainers.image.description="HTTP & GRPC callout server"
LABEL org.opencontainers.image.licenses=MIT

COPY ./lib /workdir/lib

COPY ./samples/http-grpc-callout /workdir/samples/http-grpc-callout

WORKDIR /workdir/samples/http-grpc-callout

RUN go mod download

RUN go install github.com/magefile/mage@latest

RUN mage ci

RUN go build -o ./bin/http-grpc-callout ./cmd

EXPOSE 2112

CMD [ "./bin/http-grpc-callout" ]
