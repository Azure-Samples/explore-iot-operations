.PHONY: test check build
test:
	cargo test --locked
check:
	cargo fmt --check
	cargo clippy --locked --all-targets -- -D warnings
build:
	cargo build --lib --locked --release --target wasm32-wasip2
