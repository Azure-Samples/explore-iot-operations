# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/oss/go/microsoft/golang:1.21-cbl-mariner2.0 AS build

COPY ./lib /workdir/lib

COPY ./samples/http-grpc-shift-calculation /workdir/samples/http-grpc-shift-calculation

WORKDIR /workdir/samples/http-grpc-shift-calculation

RUN go mod download

RUN go install github.com/magefile/mage@latest

RUN mage ci

RUN go build -o ./bin/http-grpc-shift-calculation ./cmd/http-grpc-shift-calculation

EXPOSE 2112

CMD [ "/bin/http-grpc-shift-calculation" ]
