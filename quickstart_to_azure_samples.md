# Migration Plan: learn-iot → explore-iot-operations

## Overview

This document describes how the AIO quickstart content from [BillmanH/learn-iot](https://github.com/BillmanH/learn-iot) is integrated into the [Azure-Samples/explore-iot-operations](https://github.com/Azure-Samples/explore-iot-operations) repository without disrupting existing samples, tutorials, and tools.

## Source Repo Structure (learn-iot)

The source repo is a standalone quickstart for deploying Azure IoT Operations on edge devices:

```
learn-iot/
├── arc_build_linux/          # Edge device installer scripts (Ubuntu/K3s)
├── arm_templates/            # ARM templates for Azure resources
├── config/                   # Config file templates and outputs
├── docs/                     # Supporting docs and images (img/)
├── external_configuration/   # Azure configuration scripts (Windows/PowerShell)
├── Fabric_setup/             # Microsoft Fabric integration guide
├── issues/                   # Issue tracking docs
├── modules/                  # Deployable edge modules
│   ├── demohistorian/        # SQL-based MQTT historian
│   ├── edgemqttsim/          # Factory equipment MQTT simulator
│   ├── sputnik/              # Simple MQTT test publisher
│   └── hello-flask/          # Basic web app for testing
├── operations/               # Dataflow YAML configurations
├── readme.md                 # Main quickstart guide
├── README_ADVANCED.md        # Detailed technical reference
└── bugfix.md
```

## Destination Repo Structure (explore-iot-operations)

The destination repo is an Azure-Samples collection with existing content:

```
explore-iot-operations/
├── samples/                  # 14 existing code samples (auth servers, WASM, dashboards, etc.)
├── tutorials/                # Event-driven Dapr tutorial
├── tools/                    # Schema generation helper
├── docker/                   # WASM Rust build container
├── docs/                     # Repo organization docs
├── README.md                 # Root README (codespace-focused getting started)
├── CONTRIBUTING.md, CODE_OF_CONDUCT.md, LICENSE.md, SECURITY.md, CHANGELOG.md
└── index.html
```

## What Was Migrated

The quickstart content has already been placed under `quickstart/`:

```
quickstart/
├── readme.md                 # Main quickstart guide
├── README_ADVANCED.md        # Detailed technical reference
├── quick_vm_build.md         # VM build instructions
├── arc_build_linux/          # Edge installer scripts
├── arm_templates/            # ARM templates
├── config/                   # Config templates
├── external_configuration/   # Azure configuration scripts
└── modules/                  # Edge modules
    ├── demohistorian/
    └── edgemqttsim/
```

### Content NOT migrated (by design)

These directories from learn-iot are **not** in this repo (they either don't exist yet, are out of scope, or are handled differently):

| Directory | Reason |
|-----------|--------|
| `Fabric_setup/` | Not yet migrated; referenced in README_ADVANCED.md |
| `operations/` | Dataflow YAML examples; not yet migrated |
| `docs/img/` | Process diagrams; image references will be removed for now |
| `issues/` | Repo-specific issue tracking; not applicable here |
| `modules/sputnik/` | Not migrated |
| `modules/hello-flask/` | Not migrated |
| `bugfix.md` | Development notes; not applicable |

---

## Changes Required

### 1. `docs/ORGANIZATION.md` — Add quickstart to repo structure

The organization doc currently only describes `samples/` and `tutorials/`. It needs a new **Quickstart** section to explain the `quickstart/` directory, its purpose, and how it differs from samples and tutorials.

**Changes:**
- Add `quickstart/` to the directory tree diagram
- Add a paragraph explaining the quickstart's purpose and scope
- Preserve all existing content about samples and tutorials

### 2. `README.md` (root) — Add quickstart entry point

The root README currently focuses on the GitHub Codespaces experience. The quickstart is a complementary path for deploying on real hardware or AKS Edge Essentials.

**Changes:**
- Add a "Quickstart: Deploy on Real Hardware" section after the existing Getting Started
- Brief description with a link to `quickstart/readme.md`
- Mention that the quickstart is for production-oriented deployments vs. the codespace path
- Keep all existing content intact (codespace badge, existing Getting Started, Contributing, etc.)

### 3. `quickstart/readme.md` — Fix references for new repo context

All internal paths and clone URLs currently reference `BillmanH/learn-iot`. These need to point to the correct locations within this repo.

**Key changes:**
- **Clone URL**: `BillmanH/learn-iot` → `Azure-Samples/explore-iot-operations`
- **ZIP download URL**: Updated similarly
- **Clone target directory**: `learn-iot` → `explore-iot-operations`
- **Working directory**: After clone, `cd` into `quickstart/`
- **Relative path references**: Paths like `arc_build_linux/installer.sh` are correct (relative to `quickstart/`)
- **Image reference**: `![Process Overview](docs/img/process_1.png)` — removed (image not migrated)
- **Image references**: `![resources pre iot](docs/img/...)` and `![resources post iot](docs/img/...)` — removed
- **Fabric setup link**: Updated to note content is in the source repo or removed
- **Issue tracker link**: Updated to this repo's issues
- **Context framing**: Add a note that this quickstart lives within the larger explore-iot-operations repo

### 4. `quickstart/README_ADVANCED.md` — Fix internal references

**Key changes:**
- **Repository structure diagram**: `learn-iothub/` → updated to reflect `quickstart/` layout
- **References to `iotopps/`**: The source repo used `iotopps/` for edge apps; this repo uses `modules/`. Update all references.
- **Clone/download references**: Same URL updates as the main readme
- **Fabric setup link**: `fabric_setup/fabric-realtime-intelligence-setup.md` → note not migrated
- **Diagnostic script paths**: Already correct (relative to `arc_build_linux/`)

---

## What This Plan Does NOT Change

- **No file moves or renames** — all quickstart files stay under `quickstart/`
- **No code changes** — scripts, templates, and application code are untouched
- **No changes to existing samples/** — all 14 existing samples remain as-is
- **No changes to tutorials/** — existing tutorial content is preserved
- **No changes to tools/, docker/, .devcontainer/** — infrastructure files untouched
- **No changes to CONTRIBUTING.md, CODE_OF_CONDUCT.md, LICENSE.md, SECURITY.md, CHANGELOG.md**
