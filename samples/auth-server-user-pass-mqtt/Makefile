#! /bin/bash

# Default target
.PHONY: all
all: run

.PHONY: run
run:	
	 RUST_LOG="info" cargo run -- --port 5200 --server-cert-chain " " --server-key " "

.PHONY: build
build:
	# TODO: Remove personalisations
	IMAGE_TAG=suneetnangia/auth-server-user-pass-mqtt:v0.1 ./deploy/build_image.sh

.PHONY: clean
clean:
	./deploy/clean.sh