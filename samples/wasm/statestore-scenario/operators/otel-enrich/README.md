# Operator Builder

This project provides a Docker-based environment for building WebAssembly Dataflow Operators.

## Prerequisites

- Docker must be installed on your machine.
- GitHub token (for private repository access) — make sure to set up a GitHub token in your Docker build secrets.

## Files

- **Dockerfile**: Defines the Rust-based build process for Dataflow Operators. The Dockerfile is based off of an image that our extension creates titled `aio-wasm-graph-wasm-rust-build`, which contains:
  - The official `rust` image based on Alpine Linux.
  - Dependencies like `clang`, `lld`, `musl-dev`, `git`, `perl`, `make`, and `cmake`.
  - Configured build environment by adding the necessary Rust, WASM, and architecture targets.

The dockerfile in your source folder is specific to each Dataflow Operator, and you can make customizations to this image to customize how each specific Operator is built.


## Setup

### Configure your GitHub token

For accessing private GitHub repositories, you'll need to provide a GitHub token. **Read-only** permissions on a fine-grained access token should suffice.

Set the `GITHUB_TOKEN` environment variable in your shell or in the `.env` file (if you are using one).

To set the environment variable in your shell, you can use the following command:

```bash
export GITHUB_TOKEN=your_personal_access_token_here
```

### Output

The built `.wasm` files will be placed in the following directory structure:

`bin/<ARCH>/<BUILD_MODE>/`


For example, if you use the default architecture (`x86_64`) and build mode (`release`), the `.wasm` file will be located in:

`bin/x86_64/release/`

## Troubleshooting

- Ensure Docker is installed and running on your machine.
- If you encounter permission errors with the GitHub token, check the file path and permissions for the token.
