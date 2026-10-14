# Publishing AI agent and relay artifacts

The manual [AI GHCR workflow](../.github/workflows/ai-ghcr.yaml) copies agent and
relay images, prepares charts with GHCR image defaults, and signs the new chart
digests using Cosign with GitHub OIDC. It does not need a maintained signing key,
certificate, PAT, or ADO GHCR publishing credential.

## Run the workflow

Run **Publish AI Agent and Relay to GHCR** from the trusted release branch
(normally `main`). Supply:

- `sourceRegistry`: the anonymously readable source registry, normally
  `mqbuilds.azurecr.io`.
- `imageTag`: the existing agent/relay image tag.
- `chartVersion`: the original source chart version, before GHCR repackaging.

Prefer immutable Official build tags, for example `1.0.0-rc-185698613`, for both
version inputs. The published image tag remains unchanged; the chart version
becomes `<chartVersion>-ghcr`.

Artifacts are published under the lowercase workflow repository path:

```text
ghcr.io/<owner>/explore-iot-operations/aio-ai-agent:<imageTag>
ghcr.io/<owner>/explore-iot-operations/aio-ai-relay:<imageTag>
ghcr.io/<owner>/explore-iot-operations/helm/aio-ai-agent:<chartVersion>-ghcr
ghcr.io/<owner>/explore-iot-operations/helm/aio-ai-relay:<chartVersion>-ghcr
```

On the upstream repository, `<owner>` is `azure-samples`; a fork uses its own
owner in both the artifact paths and embedded image references.

The workflow resolves all source digests and validates both repackaged charts
before publishing. It copies images first, preserving their digests, platforms,
and OCI referrers. It then pushes and signs the new chart digests and verifies
their signatures. Publishing is not atomic: a later failure can leave images or
an unsigned chart uploaded. Consume only a successful run's verified digest
references, which are recorded in its summary.

The `GITHUB_TOKEN` needs package write access. Confirm the intended package
visibility separately; publishing does not automatically make a package public.
Protect the release branch and workflow changes, and pin third-party actions.

## Signing and verification

`packages: write` authorizes registry publication. `id-token: write` lets Cosign
obtain a GitHub OIDC identity and a short-lived Sigstore certificate. Signing
uses Sigstore's public transparency infrastructure; workflow identity and signing
metadata are public. The private signing key is ephemeral.

The repackaged charts have **new GitHub/Cosign signatures**, not the original
Microsoft Official/Notary signatures. The workflow never copies the source
chart's signatures to a modified chart. It pins source digests but does not
perform Microsoft Official signature/trust-policy verification on the source
artifacts.

Use Cosign v3 to verify a chart by the digest recorded in a successful run:

```bash
cosign verify \
  --certificate-identity 'https://github.com/Azure-Samples/explore-iot-operations/.github/workflows/ai-ghcr.yaml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  'ghcr.io/azure-samples/explore-iot-operations/helm/aio-ai-agent@sha256:<digest>'
```

For a fork or another release branch, configure the exact identity you
independently trust. The run summary records the actual signing identity; do not
automatically trust an arbitrary identity merely because a run reports it.
Do not disable transparency or certificate verification.

Ordinary `helm install` does not enforce Cosign signatures. Verify the expected
digest before installation, then install that digest rather than a mutable tag.
If Microsoft Official signing authority is required, use an Official-signed
GHCR chart variant with a copy-only publisher instead of this repackaging flow.
Do not pass an already prepared ADO `-ghcr` chart as the source for this workflow.

## Deployment scope

The charts no longer need agent/relay image-registry overrides during installation.
Required model, identity, and relay configuration is unchanged. The agent chart's
optional MCP/Kubernetes dependencies remain bundled as provided by the source,
including their original image registries. Feature enablement defaults are also
unchanged.

## Local workflow checks

With Python 3.12 (or a patched Python supporting `tarfile`'s data filter),
PyYAML, Helm 3, jq, and Mike Farah's yq v4 installed, run:

```bash
python3 -m unittest discover -s .github/tests -p 'test_ai_ghcr_workflow.py'
actionlint .github/workflows/ai-ghcr.yaml
```

The tests use real Helm/yq with fixture charts and mock registry/Cosign operations.
They do not publish artifacts or exercise a live GitHub OIDC signing session.
