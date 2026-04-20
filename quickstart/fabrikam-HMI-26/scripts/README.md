# Scripts — Fabrikam HMI-26

One-off fixes, environment patches, and helper scripts specific to the HMI-26 demo setup. These are things that don't belong in the base quickstart but need to be remembered and reproducible.

> **Convention:** Name scripts with a short verb-noun pattern and add a comment block at the top explaining what problem they solve and when to run them.

---

## Scripts in this folder

| Script | When to run | What it fixes |
|--------|-------------|---------------|
| [`start-omniverse-connector.ps1`](start-omniverse-connector.ps1) | After edge install, before opening USD stage | Starts the MQTT→Omniverse bridge with the HMI-26 config |
| [`fix-acr-pull-secret.ps1`](fix-acr-pull-secret.ps1) | When pods show `ImagePullBackOff` | Recreates the ACR pull secret in the default namespace |
| [`restart-edgemqttsim.ps1`](restart-edgemqttsim.ps1) | When the simulator stops sending messages | Force-restarts the edgemqttsim deployment |
| [`reset-foundry-service.ps1`](reset-foundry-service.ps1) | When Foundry Local service is unresponsive | Stops and restarts the Foundry Local service |

---

## Adding a new script

1. Create the `.ps1` (or `.sh`) file in this folder.
2. Add a comment block at the top (see existing scripts for the pattern).
3. Add a row to the table above.
4. If it modifies cluster state or Azure resources, note any prerequisites.

---

## References

### How to do this yourself

- [Connect to an Arc-enabled cluster (proxy)](https://learn.microsoft.com/azure/azure-arc/kubernetes/cluster-connect) — `az connectedk8s proxy` setup before running any kubectl script
- [kubectl reference](https://kubernetes.io/docs/reference/kubectl/) — commands used in the fix scripts
- [Pull from ACR in Kubernetes](https://learn.microsoft.com/azure/container-registry/container-registry-auth-kubernetes) — background for `fix-acr-pull-secret.ps1`
- [Troubleshoot Azure IoT Operations](https://learn.microsoft.com/azure/iot-operations/troubleshoot/troubleshoot) — broader troubleshooting guide for the platform the scripts support
- [Kubernetes Deployments (rollout restart)](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment) — the mechanism used in `reset-foundry-service.ps1`
