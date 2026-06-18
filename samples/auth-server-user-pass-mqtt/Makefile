#! /bin/bash

# Default target
.PHONY: all
all: run

.PHONY: run
run:	
	 RUST_LOG="info" cargo run -- --port 5200 --server-cert-chain " " --server-key " "

.PHONY: build
build:	
	./deploy/build_image.sh

.PHONY: clean
clean:
	./deploy/clean.sh