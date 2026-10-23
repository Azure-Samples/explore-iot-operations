# AI relay cloud access sample

Expose an existing in-cluster AI MCP Frontend or A2A endpoint through
authenticated Azure API Management (APIM) and Azure Relay:

```text
Client with Entra token -> APIM -> Azure Relay Hybrid Connection -> relay pod -> MCP Frontend / A2A service
```

`deploy.sh` deploys the Azure resources from `bicep/ai-relay.bicep` and installs
the published `aio-ai-relay` Helm chart. It works from any directory and does
not require a local Helm chart.

MCP endpoints are registered as native APIM MCP servers (`type: mcp`), with an
APIM backend pointing to the Relay namespace and an MCP endpoint path pointing
to the Hybrid Connection. A2A endpoints remain ordinary HTTP passthrough APIs.
The display name `aio-ai-relay MCP passthrough` describes forwarding an existing
MCP server; it does not mean that the API is registered as an ordinary REST API.

## Prerequisites

- Bash on Linux, macOS, or WSL; Azure CLI with Bicep support; Helm 3.18 or later;
  kubectl; jq; uuidgen.
- An Azure subscription, an existing resource group, and an Arc-connected
  Kubernetes cluster with Azure IoT Operations already installed. For managed
  identity mode, the Arc cluster must be in that resource group and its AIO
  extension must have a system-assigned identity.
- Azure permissions to create Relay/APIM resources and role assignments.
- Entra permissions and tenant approval to create an application, service
  principal, delegated scope, and app role. Tenant policies, including Conditional
  Access and organizational registration metadata requirements, still apply.
- A configured kubectl context for the target cluster. The script does not
  create a cluster or switch contexts.
- For MCP: an existing MCP Frontend Service, its TLS trust bundle and
  service-account-token authentication configured for the intended audience.
  The relay chart expects the AIO CA trust bundle in the same namespace.
- Published, accessible agent/relay release artifacts. The relay chart must
  use the single-endpoint `relay.*` / `endpoint.*` configuration schema.

The prepared chart and its referenced images must already be published at the
selected registry location. This sample does not publish artifacts.
The script defaults `--chart-version` to `0.1.2` and `--image-tag` to `0.1.3`, using
`oci://ghcr.io/azure-samples/explore-iot-operations/helm/aio-ai-relay` and
`ghcr.io/azure-samples/explore-iot-operations/aio-ai-relay:0.1.3`.
These versions must be available before deployment. Use `--chart-version` and
`--image-tag` to select another compatible published chart and image pair.

Check the target subscription and cluster before running:

```bash
az login
az account set --subscription '<subscription-id>'
kubectl config current-context
```

Do not use another account or tenant to bypass organization policies. If app
registration is blocked, resolve the requirements with your Entra administrator.
For example, a tenant requiring `serviceManagementReference` cannot use the
sample's basic app-creation command without an approved adaptation. The script
stops on that error; it does not fall back to anonymous access.

## Deploy MCP access

From the repository root:

```bash
bash samples/ai/deploy.sh \
  --resource-group '<resource-group>' \
  --relay-namespace-name '<globally-unique-relay-name>' \
  --apim-name '<globally-unique-apim-name>' \
  --apim-publisher-email '<publisher-email>' \
  --apim-publisher-name '<publisher-name>' \
  --chart-version '0.1.2' \
  --cluster-name '<arc-connected-cluster-name>' \
  --aio-extension-name '<azure-iot-operations-extension-name>' \
  --entra-app-name '<unique-app-name>' \
  --endpoint-protocol mcp \
  --mcp-frontend-service-name aio-mcp-frontend \
  --mcp-frontend-audience aio-mcp-frontend
```

The script downloads the chart before creating Azure resources and uses the
same local package for all releases. It does not rewrite or verify the chart's
publisher signature. If signature enforcement is required, independently verify
the published digest with the approved publisher trust policy before deployment.

No MCP role is assigned by default. Add `--mcp-role Reader` only if the existing
frontend policy authorizes that role for the relay ServiceAccount. The annotation
is a JSON array encoded as a string, `aio-mcp-auth/roles: '["Reader"]'`.
All callers through the relay share its backend MCP permissions.

The frontend Service name and its inbound SAT audience are independent. Do not
use its backend token audience as `--mcp-frontend-audience`.

## Entra caller access

The script uses the current Azure CLI profile for both ARM and Entra operations
by default. An optional `--entra-azure-config-dir` selects a separately
authenticated, policy-approved profile for Entra operations; sign in to that
profile before running the script:

```bash
AZURE_CONFIG_DIR="$HOME/.azure-ai-relay-entra" az login --allow-no-subscriptions
```

By default, each run creates a new app and rejects an existing display name rather than
modifying an app it does not own. It exposes `user_impersonation`, creates the
`AIOMcpAdmin` role for users/applications, and enables required app-role assignment.
APIM validates the caller's Entra token audience, issuer, and `AIOMcpAdmin` claim.
An administrator must assign approved callers through **Entra Enterprise
applications > your app > Users and groups**, or Microsoft Graph for application
assignments. No caller is assigned automatically.

The Entra `AIOMcpAdmin` role, the MCP Frontend `Reader` role, and Azure's Relay
Listener/Sender roles are different permissions.

### Use a manually configured app

If an administrator has already configured the API application, replace
`--entra-app-name` in the deployment command with:

```bash
--entra-app-id '<application-client-id>' \
--entra-tenant-id '<directory-tenant-id>'
```

Both values must be GUIDs, not an `api://` URI or display name. This mode makes
no Microsoft Graph calls and does not validate, modify, or delete the app.
It cannot be combined with `--entra-app-name` or `--entra-azure-config-dir`.
Configure the identifier URI `api://<application-client-id>`, the delegated
scope, the `AIOMcpAdmin` role for users/applications, the
corresponding service principal, required role assignment, and approved caller
assignments before testing authenticated access. Tenant policies still apply.

The default scope is `user_impersonation`. If the manually configured app uses
a different scope, pass its name with `--entra-app-scope`, for example
`--entra-app-scope mcp.access`. Use the scope name, not the full `api://...` URI.
In registration mode this option sets the scope created on the new app; in
existing-app mode it only sets the scope advertised by discovery.

### MCP OAuth discovery

For MCP, the script prints the public MCP URL and an OAuth protected-resource
metadata URL at `/.well-known/oauth-protected-resource/<mcp-api-path>`.
The metadata advertises the MCP resource URL, the application's tenant
authorization server, and `api://<application-client-id>/<scope-name>`.
It is public discovery information, not anonymous access to MCP tools.
It does not assign app roles, grant client consent, or acquire a caller token.
Use an organization-approved authentication method; interactive login is not
required if an approved workload identity is assigned the application role.

## A2A and dual-protocol deployment

Use `--endpoint-protocol a2a --endpoint-url 'https://<agent-service>/...'` for
A2A. `--endpoint-protocol both` creates separate `-mcp` and `-a2a` Hybrid
Connections, APIs, Helm releases, and (in SAS mode) Secrets.

The A2A leg clears the chart's MCP-specific authentication and trust defaults.
Use `--values ./a2a-values.yaml` to configure the A2A endpoint's own credentials
and TLS trust. For example:

```yaml
endpoint:
  auth:
    kind: bearer-token
    file: /var/run/secrets/tokens/a2a
  serviceAccountTokens:
    - name: a2a
      audience: your-agent-audience
```

Do not store static credentials in a committed values file. In dual-protocol
mode the values file applies to both releases; use separate single-protocol
deployments when they need different settings. Script-managed protocol, URL,
relay authentication, and MCP token settings take precedence over the values file.

Use `--chart-reference` to select another OCI chart location. This changes
where the package is fetched, not its embedded image references.

## Azure resources, cost, and cleanup

The Bicep template creates a Standard Azure Relay namespace and one Hybrid
Connection per protocol, plus a shared APIM instance (default `BasicV2`, capacity
1). **These resources incur Azure charges; APIM provisioning can take a long
time.** Use `--apim-sku` only with a SKU available in your subscription/region.
The resource group is not created by the script.

APIM management API access is restricted to version `2019-12-01` or later.
The relay API policies inherit parent inbound, outbound, and error policies.
MCP also inherits the backend forwarding policy. A2A instead uses an explicit
`forward-request buffer-response="false"` so Server-Sent Events aren't buffered
by APIM's forwarding policy. This replaces backend-policy inheritance for A2A;
incorporate any required custom parent backend logic into that policy.
After deployment, use **Calculate effective policy** in the APIM policy editor
to confirm forwarding and Entra token validation, and that A2A GET/POST operations
use the non-buffering forwarding policy.

The AIO extension identity receives the scoped **Azure Relay Listener** role.
APIM's system-assigned identity receives the scoped **Azure Relay Sender** role.
Hybrid Connections require sender authentication in both modes. `--auth-mode sas`
is for development: it creates Listen-only SAS rules and Kubernetes Secrets;
managed identity is the default.

Each SAS Secret is named `<full-helm-release-name>-hc`, so independent releases
in the same namespace don't overwrite each other's credentials. In dual-protocol
mode, the names are `<helm-release-name>-mcp-hc` and `<helm-release-name>-a2a-hc`.
Upgrading an existing SAS deployment doesn't delete its old fixed-name Secrets;
remove them only after confirming that no workloads still reference them.

The script waits up to 180 seconds for each relay Deployment after Helm
installation. It does not roll back Azure resources or Entra objects on failure.
Record the printed application ID and the ARM deployment outputs for cleanup.
In registration mode, rerunning requires a new app name or deliberate cleanup
of the previous app. Existing-app mode can reuse the manually configured app;
do not delete that app when cleaning up the sample deployment.
Never delete a shared resource group as a cleanup shortcut.

To remove the sample, uninstall only its Helm release(s), delete its SAS
Secret(s) if applicable, and remove the dedicated APIM and Relay resources and
Entra application after confirming they are not shared:

```bash
helm uninstall aio-ai-relay --namespace azure-iot-operations
# For "both", uninstall aio-ai-relay-mcp and aio-ai-relay-a2a instead.
```

Run `bash samples/ai/deploy.sh --help` for all options.
