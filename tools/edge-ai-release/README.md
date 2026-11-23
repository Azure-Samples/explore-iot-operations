# Coordinated edge AI sample release

Maintainer tooling for the
[customer prebuilt path](../../docs/edge-ai-samples-release.md). It follows the
dataflow-patterns approach: check/build once, stage OCI layouts and saved images,
then publish that exact candidate rather than rebuilding in a privileged job.

## Workflow

[Edge AI samples](../../.github/workflows/edge-ai-samples.yml) runs on changes to
either sample, this tooling, or the shared release/qualification docs.
Like `ghcr_module.yml` and `ghcr_graph.yml`, it runs automatically on matching
pushes to `main`, including PR merges. In `Azure-Samples/explore-iot-operations`,
the publishing job follows a successful candidate job without a manual dispatch.
PR runs and the candidate job never receive registry publication credentials.
The existing sample directories and other publishing workflows are unchanged.

The candidate job:

1. Tests each Python sample with its own pinned dependencies; tests the simulator
   in Python 3.12, including lint/format and strict source type checks.
2. Runs Rust formatting/unit tests/Clippy, builds five WASI components, validates
   WASM, and compiles the Bicep templates.
3. Verifies the reviewed YOLOX export, license, checksum, and tensor contract.
4. Builds and smoke-checks Linux/amd64 assistant/simulator images, labels them
   with the source revision/version, and saves them without pushing.
5. Generates environment-independent graph definitions with matching module
   tags, stages all OCI layouts, and uploads `edge-ai-candidate`.

No customer configuration, cluster credentials, physical camera, or operational
image is required. Model package verification is not a media/connector E2E test.

## Publish a version

Before the first publication, repository administrators must configure:

- An `edge-ai-release` environment with a `main`-only deployment restriction.
  Publication is automatic after checks pass unless environment protection
  rules require approval. If organizational policy requires reviewers, the
  publishing job waits for them; the workflow does not bypass that policy.
- GHCR package permissions allowing this repository's workflow to publish its
  package namespace. Set **every new package to public**, including modules,
  graphs, model, and both images. GHCR can initially create packages as private.
- Repository policies allowing the trusted publishing job to create a
  preview GitHub release/tag and attach the two JSON ledgers.

Before merging changes covered by the workflow, set an **unused explicit
version** in `release-spec.json`. Every artifact uses that version; it is not
automatically incremented and no `latest` tag is published. The merge triggers
checks, publication of all 13 artifacts, anonymous verification, and creation
of the coordinated preview release. Pushes outside the configured path filters
do not start this workflow.

Unlike publishers that replace a fixed tag, this publisher preserves released
content. A new source revision changes release provenance even for a
documentation-only update. Merging covered changes without advancing an already
published version fails the immutable-tag check rather than replacing that
release. Keep example deployment versions tied to an actually published and
appropriately qualified release, not an unpublished version bump.

For a manual run, dispatch **Edge AI samples** on `main` in
`Azure-Samples/explore-iot-operations`. An optional version overrides
`release-spec.json`; select `publish` to publish, or leave it unchecked to
build and validate only. That input controls manual runs, not main-branch pushes.
No publication is performed for PRs, forks, or pushes/dispatches on other branches.
The protected publishing job alone receives `packages: write` and
`contents: write`.

The publisher validates the candidate revision/version and every local blob,
preflights the **whole** remote artifact set for immutable-tag conflicts, copies
the staged OCI objects, and loads/pushes the saved images. Existing matching
content is not overwritten; conflicting content requires a new version.
Authentication and network failures are not interpreted as missing tags.

It then performs independent anonymous full pulls of every manifest, config,
and layer. An image config's layer identities are checked against the actual
decompressed content. Only a fully verified set gets `verification.json` and
a preview GitHub release named `edge-ai-v<VERSION>`, with both ledgers attached.
The workflow does not modify an existing GitHub release. It does not mark the
repository's overall latest release or claim live runtime qualification.

### Partial failures and retries

Registries do not provide a multi-package transaction. A failure can leave some
tags uploaded; they are not a completed release. For first-time private packages,
set their visibility to public and **rerun the failed publishing job only**,
using the same retained candidate. Candidate artifacts are retained for 14 days.
The script rechecks the full set before resuming.

Do not rerun all jobs to recreate an immutable version: dependency resolution or
image build metadata can change its bytes. If the candidate expired or content
differs, choose a new version. Do not delete/replace conflicting tags to force a
pass. Downloaded release ledgers remain available as GitHub release assets after
the transient CI artifacts expire.

Registry credentials are placed in an isolated `DOCKER_CONFIG`, supplied over
stdin, and removed in an always-run cleanup step. Anonymous verification uses
a separate empty credential file and never relies on the publishing token.

## Local checks and candidate preparation

Use a task-local environment with the assistant's development dependencies and
the inference model requirements. The predictive sample's separate test
environment uses its own requirements; do not combine the two `jsonschema` pins.
Docker, ORAS 1.3+, Rust 1.90.0, and the `wasm32-wasip2` target are required for
candidate preparation.

From the repository root, with the appropriate Python environment active:

```bash
python -m pytest tools/edge-ai-release
bash samples/edge-predictive-inference/build.sh
bash samples/aio-mcp-ai-assistant/native-camera-actions/build.sh
python samples/edge-predictive-inference/models/prepare.py
python tools/edge-ai-release/release.py build-images --version 0.1.0-rc.1
python tools/edge-ai-release/release.py stage \
  --version 0.1.0-rc.1 --output tools/edge-ai-release/.candidate
```

The output directory must not already exist. These commands do not publish.
Dirty-checkout candidates are marked `sourceDirty: true` and cannot be published
by the release tool. Use them only for local checks.

For a downloaded public release ledger, no build tools or images are needed:

```bash
python tools/edge-ai-release/release.py verify /path/to/release-ledger --published
```

Keep [cluster qualification](../../docs/edge-ai-samples-validation.md) separate.
Only update that record from actual authorized deployment evidence.
