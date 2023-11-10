# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/oss/go/microsoft/golang:1.21-cbl-mariner2.0 AS build

COPY ./lib /workdir/lib

COPY ./samples/callout /workdir/samples/callout

WORKDIR /workdir/samples/callout

RUN go mod download

RUN go install github.com/magefile/mage@latest

RUN mage ci

RUN go build -o ./bin/callout ./cmd/callout

EXPOSE 2112

CMD [ "/bin/callout" ]
