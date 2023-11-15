# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/oss/go/microsoft/golang:1.21-cbl-mariner2.0 AS build

COPY ./lib /workdir/lib

COPY ./samples/industrial-data-simulator /workdir/samples/industrial-data-simulator

WORKDIR /workdir/samples/industrial-data-simulator

RUN go mod download

RUN go install github.com/magefile/mage@latest

RUN mage ci

RUN go build -o ./bin/industrial-data-simulator ./cmd

EXPOSE 2112

CMD [ "/bin/industrial-data-simulator" ]
