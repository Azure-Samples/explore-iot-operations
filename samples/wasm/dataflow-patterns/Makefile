.PHONY: test check build
test:
	cargo test --workspace --locked
check:
	cargo fmt --check
	cargo clippy --workspace --locked --all-targets -- -D warnings
build:
	cargo build --workspace --lib --locked --release --target wasm32-wasip2
