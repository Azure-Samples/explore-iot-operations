# Publishing AI agent and relay artifacts

The manual [AI GHCR workflow](../.github/workflows/ai-ghcr.yaml) copies existing
agent/relay images and prepared Helm charts to GHCR by immutable digest. It does
not modify chart contents, rebuild images, or create signatures. Existing
signatures and other OCI referrers are retained through recursive copies.

## Prepare the charts first

Use the ADO AI Promotion preparation job (`prepareGhcrCharts=true`) to prepare
GHCR-ready agent/relay chart variants and sign them in `mqbuilds.azurecr.io`.
For a preparation-only run, set `promoteProducts=false` and `promoteMcp=false`.
The job produces a `ghcr-release.json` handoff with image/chart tags and digests.
This GitHub workflow does not read that file automatically; use its version
values as the workflow inputs.

The source charts must already contain the intended image registry, repository,
and tag. Copying a chart cannot change its embedded image references. The ADO
variants target `ghcr.io/azure-samples/explore-iot-operations`; run this workflow
in the upstream repository to publish to that matching location.

## Run the workflow

Run **Publish AI Agent and Relay to GHCR** from the trusted release branch
(normally `main`). Supply:

- `sourceRegistry`: the anonymously readable source registry, normally
  `mqbuilds.azurecr.io`.
- `imageTag`: the existing agent/relay image tag from the prepared release.
- `chartVersion`: the exact prepared source chart version, including its
  `-ghcr` suffix. The workflow does not add another suffix.

For example, for an available prepared Official build:

```text
sourceRegistry: mqbuilds.azurecr.io
imageTag:      1.0.0-rc-<official-build-id>
chartVersion:  1.0.0-rc-<official-build-id>-ghcr
```

Both images and both charts must exist at the source. The workflow resolves all
four digests before publishing and copies images before charts.

Artifacts are published under the lowercase workflow repository path:

```text
ghcr.io/<owner>/explore-iot-operations/aio-ai-agent:<imageTag>
ghcr.io/<owner>/explore-iot-operations/aio-ai-relay:<imageTag>
ghcr.io/<owner>/explore-iot-operations/helm/aio-ai-agent:<chartVersion>
ghcr.io/<owner>/explore-iot-operations/helm/aio-ai-relay:<chartVersion>
```

On the upstream repository, `<owner>` is `azure-samples`. A fork publishes under
its own owner, but the copied charts still reference their original image paths.
The workflow does not rewrite those references for a fork.

The `GITHUB_TOKEN` needs package write access. Confirm the intended package
visibility separately; publishing does not automatically make a package public.
Protect the release branch and workflow changes, and pin third-party actions.

## Integrity and signatures

Each source reference is pinned to its resolved digest for the recursive copy.
The destination manifest digest must match the source digest. Chart bytes,
versions, bundled dependencies, feature defaults, and embedded image references
remain unchanged. Original signatures remain applicable to the unchanged digest;
the workflow does not replace them with GitHub/Cosign signatures and needs no
OIDC signing permission or signing key.

Digest equality is an integrity check, not publisher authentication. The workflow
does not require signatures or perform cryptographic verification against a
publisher trust policy. An unsigned source remains unsigned. Verify required
signatures with the appropriate verifier and independently trusted publisher
policy before installation. Ordinary Helm installation does not automatically
enforce OCI Cosign or Notary signatures.

Publishing is not atomic: a later failure can leave earlier artifacts uploaded.
Only treat a successful run as a completed release; its summary records the
digest-pinned sources and destination tags. Use immutable digests for deployment.

## Deployment scope

The ADO-prepared charts already have GHCR agent/relay image defaults. Required
model, identity, and relay configuration is unchanged. The agent chart's optional
MCP/Kubernetes dependencies remain bundled as provided by the source, including
their original image registries. Feature enablement defaults are unchanged.

## Local workflow checks

With Python 3, PyYAML, jq, and actionlint installed, run:

```bash
python3 -m unittest discover -s .github/tests -p 'test_ai_ghcr_workflow.py'
actionlint .github/workflows/ai-ghcr.yaml
```

The tests mock registry transport and exercise the actual workflow scripts,
including recursive chart/referrer preservation, source resolution, copy and
digest failures, exact version handling, fork behavior, and credential cleanup.
They do not publish artifacts or verify real registry signatures.
