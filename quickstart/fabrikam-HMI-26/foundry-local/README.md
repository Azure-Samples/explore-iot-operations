# Foundry Local — Fabrikam HMI-26

This folder covers the **Foundry Local** setup used in the HMI-26 demo to run AI inference and agent orchestration on or near the edge device.

Foundry Local allows models to run locally (on the edge machine or a nearby workstation) and be consumed by the same agent code that targets Azure AI Foundry — with no changes to the application.

---

## What Foundry Local Does in This Demo

| Role | Details |
|------|---------|
| **OEE Anomaly Detection** | Runs a language model over the `factory/` MQTT stream to flag anomalies |
| **Maintenance Advisor** | Agent that answers natural-language questions about machine health |
| **Dataflow Enrichment** | Enriches telemetry with AI-generated labels before forwarding to Fabric |

---

## Prerequisites

- Windows 11 (24H2+) or Windows Server 2025 with WSL2, **or** Ubuntu 22.04+
- At least 16 GB RAM; GPU optional but recommended for inference speed
- `winget` (Windows) or `curl` (Linux) for install
- Azure CLI with active login (`az login`)
- Docker (for containerized model serving, optional)

---

## Installation

### Windows

```powershell
winget install Microsoft.FoundryLocal
```

After install, open a new terminal and verify:

```powershell
foundry --version
```

### Linux (Ubuntu)

See the [Foundry Local documentation](https://learn.microsoft.com/azure/ai-foundry/foundry-local/overview) for the current Linux install instructions.

---

## Starting Foundry Local

```powershell
# Start the local service (runs on http://localhost:5272 by default)
foundry service start
```

Confirm it is running:

```powershell
foundry service status
```

---

## Model Configuration

### Listing available models

```powershell
foundry model list
```

### Recommended models for HMI-26

| Use case | Model | Alias |
|----------|-------|-------|
| Chat / agent reasoning | `phi-4-mini` | `phi4mini` |
| Embeddings | `all-minilm-l6-v2` | `minilm` |

### Downloading a model

```powershell
foundry model download phi-4-mini
```

### Running a model

```powershell
foundry model run phi-4-mini
```

---

## Agent Configuration

Agent prompts and tool definitions for the HMI-26 maintenance advisor are stored in this folder.

| File | Purpose |
|------|---------|
| [`agent-system-prompt.md`](agent-system-prompt.md) | System prompt for the maintenance advisor agent |
| [`foundry-config.json`](foundry-config.json) | Foundry Local endpoint and model configuration |

---

## Connecting the Agent to IoT Operations Telemetry

The agent reads telemetry from the MQTT broker or from Fabric via the Fabric connector. The typical flow:

```
MQTT Broker
  └── Dataflow (IoT Operations) → Event Hub / Fabric Eventhouse
        └── Agent tool (HTTP call) → Foundry Local inference
              └── Response → Dashboard / Omniverse HUD
```

See the [Fabric Connectors](../fabric-connectors/README.md) doc for the dataflow side.

---

## Environment Variables

Set these before starting the agent application:

```powershell
$env:FOUNDRY_ENDPOINT = "http://localhost:5272"
$env:FOUNDRY_MODEL    = "phi-4-mini"
```

> **Note:** If your agent code also calls Azure services (e.g., reads from Fabric or Event Hubs), you may also need `$env:AZURE_SUBSCRIPTION_ID = "<your-subscription-id>"` and an active `az login` session. That is not required for Foundry Local itself.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `foundry service start` hangs | Check that no other process owns port 5272 (`netstat -ano | findstr 5272`) |
| Model download fails | Re-run with `--verbose`; check proxy / firewall settings |
| High memory usage | Switch to `phi-4-mini` (smaller footprint) or reduce context window |
| Agent not reaching MQTT | Confirm broker SAT token is mounted; check pod logs |

---

## References

- [Foundry Local documentation](https://learn.microsoft.com/azure/ai-foundry/foundry-local/overview)
- [Foundry Local GitHub](https://github.com/microsoft/Foundry-Local)
- [Microsoft Agent Framework](https://learn.microsoft.com/azure/ai-foundry/agents/overview)
