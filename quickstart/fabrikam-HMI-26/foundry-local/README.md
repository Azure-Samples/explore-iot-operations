# Foundry Local - Fabrikam HMI-26

This folder covers the **Foundry Local** setup used in the HMI-26 demo.

In this demo, Foundry Local is deployed **onto the K8s edge cluster** via Helm, not as a standalone desktop application. It provides an OpenAI-compatible inference endpoint directly on the edge, enabling sub-second LLM responses without cloud round-trips.

This powers **"Trusted On-Prem AI at the Point of Action"** - a local model that consumes live recycling plant telemetry to provide real-time operator recommendations: contamination detection, sorter recalibration prompts, and quality ops triage.

---

## What Foundry Local Does in This Demo

| Role | Details |
|------|---------|
| **Colour Quality Ops** | Triages out-of-tolerance RGB pellet colour scan readings from PKG-01 |
| **Contamination Detection** | Processes NIR sorter and wash-stage telemetry to surface contamination risks |
| **Operator Recommendations** | Produces prioritised machine check lists for shift operators in real time |

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Arc-connected K8s cluster | The edge cluster must be Arc-enabled |
| Azure IoT Operations installed | Installs `cert-manager` and `trust-manager` (required dependencies) |
| Helm 3.x | `winget install Helm.Helm` on Windows |
| kubectl access | Via `az connectedk8s proxy -n <cluster-name> -g <resource-group>` |
| No GPU required | CPU-only models are used in this demo |

---

## Deployment

### Step 1 - Patch trust-manager

Azure IoT Operations installs trust-manager without the `--secret-targets-enabled` flag that Foundry Local requires. Patch it before installing:

```powershell
# Add the --secret-targets-enabled arg
kubectl patch deployment trust-manager -n cert-manager --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--secret-targets-enabled=true"}
]'

# Grant trust-manager RBAC for secrets
kubectl patch clusterrole trust-manager -n cert-manager --type='json' -p='[
  {"op":"add","path":"/rules/-","value":{
    "apiGroups":[""],"resources":["secrets"],
    "verbs":["get","list","create","patch","watch","delete"]
  }}
]'

kubectl rollout status deployment/trust-manager -n cert-manager --timeout=60s
```

### Step 2 - Install the Foundry Local Inference Operator

```powershell
helm install inference-operator `
  oci://mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator `
  --version 0.0.1-prp.5 `
  --namespace foundry-local-operator `
  --create-namespace
```

Verify all pods are running:

```powershell
kubectl get pods -n foundry-local-operator
# Expected: inference-operator (2/2), telemetry-collector (4/4)
```

### Step 3 - Deploy the model

List available CPU models from the built-in catalog:

```powershell
kubectl get cm foundry-local-catalog -n foundry-local-operator -o yaml | Select-String "displayName"
```

Recommended model for HMI-26 (CPU-only, fits constrained clusters):

| Model | Size | Notes |
|-------|------|-------|
| `qwen3-0.6b-generic-cpu` | 0.58 Gi | Used in HMI-26 demo |
| `qwen2.5-1.5b-instruct-generic-cpu` | 1.40 Gi | Larger option if memory allows |

---

## Agent Configuration

Agent prompt and endpoint configuration for the HMI-26 Colour Quality Ops Agent are in this folder:

| File | Purpose |
|------|---------|
| [`agent-system-prompt.md`](agent-system-prompt.md) | System prompt for the Colour Quality Ops Agent |
| [`foundry-config.json`](foundry-config.json) | Foundry Local endpoint and model configuration |

---

## How the Agent Connects to Plant Telemetry

```
MQTT Broker (fabrikam/packaging)
  └── Colour scan payload (RGB + lot_id)
        └── Foundry Local inference (on-cluster)
              └── Operator recommendation -> HMI dashboard / Omniverse HUD
```

For the Fabric side of the data flow, see [Fabric Connectors](../fabric-connectors/README.md).

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Helm install fails with cert error | Check trust-manager patch was applied and pod restarted |
| Pods stuck in `Pending` | Check node memory; use the 0.58 Gi `qwen3-0.6b` model |
| Inference endpoint times out | Check `kubectl logs -n foundry-local-operator` for OOM or crash |
| Agent prompt not triggering | Confirm `fabrikam/packaging` topic is receiving messages from edgemqttsim |

---

## References

- [Foundry Local documentation](https://learn.microsoft.com/azure/ai-foundry/foundry-local/overview)
- [Microsoft Agent Framework](https://learn.microsoft.com/azure/ai-foundry/agents/overview)