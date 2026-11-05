# Akri Connector Builder

Build specification-driven **C#/.NET or Rust** Akri connectors for Azure IoT Operations, including
source, tests, connector metadata, and documentation.

> [!IMPORTANT]
> Carefully review and independently validate AI-generated code and artifacts against your specifications,
> security requirements, and target environment before using them in production.

## Launch the agent

### Prerequisites

- **GitHub Copilot CLI newer than 1.0.105**, signed in with access to **Claude Opus 5.5**, the
  coordinator's required model. Use `/login` in Copilot if needed.
- **PowerShell (`pwsh`) newer than 7.6.3**, **Node.js 22.3 or later**, and **Git**, available on `PATH`.
- **Docker Desktop with a running Linux-container engine** that permits the privileged local
  development runtime, plus access to required container images and package feeds.
- **.NET SDK 9 or later for C#/.NET**. Rust validation uses a containerized toolchain; host Rust,
  Cargo, and OpenSSL are not required.
- A **Git repository** for your connector and specification files. Initialize one with `git init`
  if needed. No Azure subscription or deployed Azure IoT Operations instance is needed for local generation.

Run these commands in PowerShell to install the released plugin and prepare the local runtime:

```powershell
copilot plugin install Azure-Samples/explore-iot-operations:agents/akri-connector-builder
docker pull mcr.microsoft.com/azureiotoperations/devx-runtime:0.1.13
docker tag mcr.microsoft.com/azureiotoperations/devx-runtime:0.1.13 devx-runtime
```

From inside **your connector's Git repository**, launch:

```powershell
copilot --agent "akri-connector-builder:akri-connector-builder"
```

The selected agent starts its **bundled MCP server automatically**: no npm installation, manual
MCP build, environment-variable setup, or global MCP registration is needed. Inspect its connection
with `/mcp show akri-connectors-mcp`. The workflow manages the local Docker network and runtime volume.

## Choose your workflow

The agent asks which experience you want before gathering inputs:

| Option | What happens |
|---|---|
| **Create connector E2E (includes metadata authoring)** | Implements, builds, tests, reviews, documents, and locally validates the connector, then cleans up validation resources. |
| **Create connector E2E + run in local containers for testing** | Runs the same complete workflow, then demonstrates the final connector and leaves the AIO runtime, generated simulator, connector, and MQTT observer running for inspection. |

**Choose live testing** to inspect final telemetry and resource health; otherwise choose E2E.
Both require Docker and include mandatory local integration validation. E2E alone skips only the
final running demonstration, not testing.

For live testing, use the generated `local-live-test.md` for observations and cleanup instructions.
Follow telemetry with `docker logs -f {connector-name}-mqtt-observer`; request cleanup explicitly
when finished. A user-provided endpoint is not owned or stopped by the workflow.

## Provide inputs that make the agent successful

The agent asks questions one at a time and confirms your requirements before implementation.
Prepare:

- **Authoritative specifications:** exact repository-relative paths, such as
  `docs\protocol.pdf, docs\device.md`. PDF, UTF-8 text, Markdown, HTML, and Word `.docx` are supported.
  Keep documents in a neutral folder such as `docs`, not agent instruction/configuration locations.
  Do not paste specifications or attach them in chat.
- **Implementation scope:** protocol, variant/version, client/server role, language, and either an
  exact NuGet package/crate and version or a from-scratch implementation. Include dependency/API
  documentation and identify the purpose of supporting documents or existing code. The agent does
  not search the web for missing specifications.
- **Concrete modeling and acceptance examples:** describe device endpoints, assets, datasets/data
  points, addresses, types, units, encoding/byte order, destinations, and any events, streams, or
  actions. Include sample inputs/expected outputs, error cases, and timing expectations so AIO
  Device/Asset configuration and metadata match actual protocol behavior.
- **Only capabilities you need now:** polling, MQTT publishing, events, streams, last-known state,
  management actions, and discovery are separate selections. More scope means more implementation
  and review work; resilience, health, and observability are always included.
- **A reproducible test scenario:** prefer an agent-generated deterministic Docker simulator unless
  you already have a suitable endpoint. Local validation supports **anonymous authentication only**.
  Provide realistic, non-secret fixtures; never provide credentials, tokens, or certificates.
- **Release metadata:** description, semantic version/preview status, image name/tag, required
  architectures, and optional maintainer/vendor values (or explicitly omit them).

## What each skill does

The agent coordinates the development skills automatically; you do not need to run them individually.
Marketplace preparation is a separate, optional follow-up.

| Skill | Purpose |
|---|---|
| [Scaffolding](skills/aio-connector-scaffolding/SKILL.md) | Creates the canonical workspace and compilable, specification-grounded skeleton. |
| [Core implementation](skills/aio-connector-core-implementation/SKILL.md) | Implements SDK-backed behavior, selected capabilities, tests, and conformance evidence. |
| [Cross-check](skills/aio-connector-cross-check/SKILL.md) | Finds and fixes gaps between specifications, implementation, and tests. |
| [Readability refactoring](skills/aio-connector-readability-refactoring/SKILL.md) | Simplifies code without changing behavior. |
| [Performance optimization](skills/aio-connector-performance-optimization/SKILL.md) | Makes evidence-based, behavior-preserving performance improvements. |
| [Final cross-check](skills/aio-connector-final-cross-check/SKILL.md) | Rechecks conformance after refactoring and optimization. |
| [Metadata authoring](skills/aio-connector-metadata-authoring/SKILL.md) | Derives and schema-validates metadata for implemented configuration and capabilities. |
| [Security review](skills/aio-connector-security-review/SKILL.md) | Reviews security, fixes specification-compatible issues, and records findings. |
| [Test environment](skills/aio-connector-test-environment/SKILL.md) | Prepares an anonymous endpoint and matching schema-valid Device/Asset resources. |
| [Local integration validation](skills/aio-connector-local-validation/SKILL.md) | Runs specification-derived scenarios through the local AIO runtime, then cleans up. |
| [User documentation](skills/aio-connector-user-documentation/SKILL.md) | Explains setup, configuration, usage, deployment, and troubleshooting. |
| [Technical documentation](skills/aio-connector-technical-documentation/SKILL.md) | Documents the finished architecture and implementation. |
| [AI notices](skills/aio-connector-ai-notice/SKILL.md) | Adds format-safe AI provenance notices and revalidates the generated files. |
| [Live testing (optional)](skills/aio-connector-local-live-testing/SKILL.md) | Demonstrates final behavior and resource health, leaving containers running. |
| [Marketplace publication (optional)](skills/marketplace-connector-publication/SKILL.md) | Authors Helm/CNAB source and a handoff for a Marketplace container offer. |

The workflow also performs independent adversarial convergence before AI notices and finishes with
a session summary and user review. Its execution contract is defined in [workflow.json](workflow.json).

## After a successful run

Your workspace is `connectors\{connector-name}` inside the active Git repository.

1. **Review before shipping.** Read `what-was-done.md`, source, tests, conformance evidence,
   `SECURITY-REVIEW.md`, and the generated `user-docs` and `tech-docs`. Confirm behavior against your
   specifications and request any corrections.
2. **Publish to ACR if needed.** After confirming conformance, publish both the connector image and
   `ConnectorMetadata\connector-metadata.json` as a metadata artifact through your approved release
   process. Set up ACR, Azure CLI/Docker, ORAS, and registry authentication for this stage; the
   generation workflow does not publish artifacts.
3. **Prepare a Marketplace offer if needed.** In a separate general-purpose Copilot session with
   the plugin enabled, ask it to use `marketplace-connector-publication` for your completed connector.
   The skill prepares container-offer source artifacts and instructions; you review them, complete
   external CPA packaging/validation, and submit through Partner Center. It does not submit or
   certify the offer automatically.

Report issues through [GitHub Issues](https://github.com/Azure-Samples/explore-iot-operations/issues).
