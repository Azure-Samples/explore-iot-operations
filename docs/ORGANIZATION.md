# Explore IoT Operations Organization

## Structure

Explore IoT Operations is a collection of tools, samples, and quickstart deployments for customers of Azure IoT Operations. To keep the project understandable and extensible to future additions, the following conventions should be followed for repository structure.

```
├── quickstart/
│   ├── arc_build_linux/
│   ├── arm_templates/
│   ├── config/
│   ├── external_configuration/
│   ├── modules/
│   ├── readme.md
│   └── README_ADVANCED.md
├── samples/
│   ├── sample1/
│   ├── ...
│   ├── sampleN/
├── tutorials/
└── README.md
```

**Quickstart** (`./quickstart`) is an automated, end-to-end deployment of Azure IoT Operations on real edge hardware (Ubuntu/K3s) or a single Windows machine (AKS Edge Essentials). It includes edge installer scripts, Azure configuration scripts, ARM templates, and deployable edge modules (factory simulator, MQTT historian). The quickstart is designed for users who want to stand up a production-oriented IoT Operations environment — as opposed to the GitHub Codespaces path — and validate their own dataflow pipelines and Fabric integration. See the [quickstart README](../quickstart/readme.md) for full instructions and the [advanced guide](../quickstart/README_ADVANCED.md) for detailed technical reference.

**Samples** (`./samples`) are tools or code samples which can be written in any language. They should be given a descriptive name which adequately describes their purpose, and should include some level of documentation regarding their usage.

**Tutorials** (`./tutorials`) are collections of code and documentation which are used together to provide a step-by-step walkthrough to demonstrate the capabilities of some feature of Azure IoT Operations. These typically serve a more narrow scope than that of a tool or code sample, designed to exercise specific facets of Azure IoT Operations.

## Linting, Formatting, and Testing Requirements

Linting, formatting, and testing are not required but are highly recommended.
