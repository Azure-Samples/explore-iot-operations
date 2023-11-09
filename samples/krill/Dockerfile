# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/oss/go/microsoft/golang:1.21-cbl-mariner2.0 AS build

COPY ./lib /workdir/lib

COPY ./samples/krill /workdir/samples/krill

WORKDIR /workdir/samples/krill

RUN go mod download

RUN go fmt ./...

RUN go build -o ./bin/krill ./cmd/krill

EXPOSE 2112

CMD [ "/bin/krill" ]
