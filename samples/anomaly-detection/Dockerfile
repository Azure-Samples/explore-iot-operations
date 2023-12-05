# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/oss/go/microsoft/golang:1.21-cbl-mariner2.0 AS build
LABEL org.opencontainers.image.source=https://github.com/Azure-Samples/explore-iot-operations
LABEL org.opencontainers.image.description="Industrial anomaly detection server"
LABEL org.opencontainers.image.licenses=MIT

COPY ./lib /workdir/lib

COPY ./samples/anomaly-detection /workdir/samples/anomaly-detection

WORKDIR /workdir/samples/anomaly-detection

RUN go mod download

RUN go install github.com/magefile/mage@latest

RUN mage ci

RUN go build -o ./bin/anomaly-detection ./cmd

EXPOSE 2112

CMD [ "./bin/anomaly-detection" ]
