# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/oss/go/microsoft/golang:1.21-cbl-mariner2.0

COPY go.mod /tool/go.mod
COPY go.sum /tool/go.sum
COPY lib /tool/lib
COPY tools/example /tool/example

