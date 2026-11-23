# Configure shared storage with Azure Container Storage enabled by Azure Arc

The person-detection pipeline exchanges prepared input and raw output files
through one ReadWriteMany (RWX) persistent volume claim (PVC). The data flow
runtime, inference connector, and inspection pod can run on different nodes.
They must see the same files with UID/GID `65532`.

This guide provides an Azure Container Storage enabled by Azure Arc (ACSA)
configuration and a cross-node verification job. ACSA local shared volumes keep
these files in the cluster; this configuration does not upload them to Azure
Blob Storage. The backing disks can still be Azure managed disks on AKS.

The MCP assistant does not mount this claim. When you demonstrate MCP questions
over this pipeline's observations, deploy this storage for the **inference
producer**, not for the assistant itself. Foundry's model cache and the
assistant's in-memory pending approvals are also separate from this claim.
Restarting the assistant discards those approvals; this PVC does not persist them.

## 1. Review the existing platform

Have the cluster owner perform this section. Installing ACSA adds cluster-wide
controllers and a CSI driver and can provision chargeable backing disks. Reuse
an existing compatible installation rather than installing a second extension
or replacing its configuration.

Start in `samples/edge-predictive-inference` with a populated `config.json`:

```bash
CONTEXT=$(jq -er '.kubeContext' config.json)
ARC_SUBSCRIPTION_ID="REPLACE_WITH_ARC_CLUSTER_SUBSCRIPTION"
ARC_RESOURCE_GROUP="REPLACE_WITH_ARC_CLUSTER_RESOURCE_GROUP"
ARC_CLUSTER="REPLACE_WITH_ARC_CLUSTER_NAME"

az k8s-extension list \
  --subscription "$ARC_SUBSCRIPTION_ID" --resource-group "$ARC_RESOURCE_GROUP" \
  --cluster-name "$ARC_CLUSTER" --cluster-type connectedClusters \
  --query "[?extensionType=='microsoft.arc.containerstorage'].{name:name,version:currentVersion,state:provisioningState}" \
  --output table

kubectl --context "$CONTEXT" get storageclass
```

These Azure identifiers refer to the **Arc-connected cluster**, which need not
be in the same resource group as the AIO instance. Keep the Kubernetes context
explicit. Follow the platform's existing Azure CLI authentication process.

ACSA requires compatible certificate and trust managers. Reuse those installed
for AIO; do not install duplicate controllers. Review the supported platform
requirements in the [ACSA installation documentation][install] and the sample's
[recorded platform versions and qualification results][validation].

## 2. Install and configure ACSA only when needed

For a new installation, select the ACSA version from the qualification record.
The private qualification environment uses `2.15.1`. Its cross-node checksum
check passed as UID/GID `65532` on two different AKS nodes, and the graph and
connector exchanged real inference files across nodes. This qualifies the
storage path in that environment, not every scenario or the pending GHCR
release; consult the [full qualification record][validation].

```bash
ACSA_VERSION="2.15.1"
az k8s-extension create \
  --subscription "$ARC_SUBSCRIPTION_ID" --resource-group "$ARC_RESOURCE_GROUP" \
  --cluster-name "$ARC_CLUSTER" --cluster-type connectedClusters \
  --name azure-arc-containerstorage --extension-type microsoft.arc.containerstorage \
  --version "$ACSA_VERSION" --auto-upgrade-minor-version false
```

After the extension is ready, inspect its existing configuration:

```bash
kubectl --context "$CONTEXT" get edgestorageconfigurations -o yaml
```

If a configuration exists, have its owner confirm that it provides local shared
volumes. **Do not apply the following file over an existing configuration.**
For a new installation, review
[`edge-storage-configuration.yaml`](../kubernetes/platform/edge-storage-configuration.yaml):

```yaml
apiVersion: arccontainerstorage.azure.net/v1
kind: EdgeStorageConfiguration
metadata:
  name: edge-storage-configuration
spec:
  defaultDiskStorageClasses:
    - default
    - local-path
```

These names are candidate **backing disk** classes from the documented Arc-enabled
AKS configuration. Confirm that an appropriate backing class exists; change the
list with the storage owner if your cluster uses different names. Do not select
`unbacked-sc` as its own backing class.

Apply the reviewed configuration and wait for the local shared-volume class:

```bash
kubectl --context "$CONTEXT" apply \
  -f kubernetes/platform/edge-storage-configuration.yaml
kubectl --context "$CONTEXT" wait --for=create storageclass/unbacked-sc --timeout=300s
kubectl --context "$CONTEXT" -n azure-arc-containerstorage get pods
kubectl --context "$CONTEXT" get storageclass unbacked-sc -o yaml
```

This does not change Kubernetes' default storage class. ACSA uses its backing
storage to provide the shared filesystem; an ordinary Azure Disk or local-path
RWO claim is not a replacement for the resulting `unbacked-sc` RWX claim.

## 3. Create and verify the sample's shared claim

Set `"storageClassName": "unbacked-sc"` in `config.json` and retain a dedicated
`dataClaimName`. Do not change the storage class of an existing claim or delete a
claim containing data to switch drivers.

With the sample's other prerequisites configured:

```bash
./deploy.sh preflight config.json
./deploy.sh storage config.json
./deploy.sh storage-check config.json
```

`storage` creates the sample's 2 GiB RWX claim, initializes its `inputs` and
`responses` directories as UID/GID `65532`, and installs the bounded-retention
cleanup job. It does not install or reconfigure ACSA.

`storage-check` creates a uniquely named, two-pod
[`verification job`](../kubernetes/storage-check.yaml). Required pod anti-affinity
places the pods on **different nodes**. Each pod writes files in both sample
directories and verifies the other pod's SHA-256 checksums. The job uses the
same UID/GID as the graph and connector, no Kubernetes API token, and a
read-only container root filesystem.

Success requires both completions and two `PASS` lines identifying different
nodes. Each pod removes only the peer files from its own verification run; the
helper then removes the successful job and its pods. `Bound`, an RWX declaration,
or two pods on one node is not sufficient evidence.

Run one verification job at a time. At least two schedulable nodes are required.
For a single-node installation, omit this check and explicitly record that
cross-node access was not verified.

## Troubleshooting and ownership

- **Pending claim or pod:** inspect the claim, pod, events, ACSA controllers,
  backing class, capacity, and scheduling constraints. Do not replace the claim
  with an `emptyDir` or a node-local volume to make the check pass.
- **Permission denied:** confirm actual UID/GID and the CSI driver's group
  handling with the storage owner. Do not disable non-root policy or make the
  shared filesystem world-writable.
- **Failed verification:** the helper leaves the named job and pods for diagnosis.
  Inspect their logs before deleting that specific job. Any test files left
  behind have run-specific names in the sample's existing cleanup directories.
- **Azure Files policy failure:** Azure Files and ACSA are different storage
  paths. A policy prohibiting Storage account Shared Key access can block a
  key-based Azure Files class. Do not weaken that policy; this local shared-volume
  setup does not require Storage account Shared Key credentials.

Normal sample cleanup removes its claim and workloads, not ACSA, its CSI driver,
the cluster-wide `EdgeStorageConfiguration`, or the backing storage classes.
Only the platform owner should remove those shared components after checking
all consumers. Follow [sample storage retention and cleanup](operations.md)
and the [ACSA local shared-volume documentation][local-shared].

[install]: https://learn.microsoft.com/azure/azure-arc/container-storage/howto-install-edge-volumes
[local-shared]: https://learn.microsoft.com/azure/azure-arc/container-storage/howto-configure-local-shared-edge-volumes
[validation]: ../../../docs/edge-ai-samples-validation.md
