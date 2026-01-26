# Explore IoT Operations Organization

## Structure

Explore IoT Operations is a collection of tools and samples for customers of Azure IoT Operations. To keep the project understandable and extensible to future additions, the following conventions should be followed for repository structure.

```
├── samples/
│   ├── sample1/
│   ├── ...
│   ├── sampleN/
├── tutorials/
└── README.md
```

**Samples** (`./samples`) are tools or code samples which can be written in any language. They should be given a descriptive name which adequately describes their purpose, and should include some level of documentation regarding their usage.
**Tutorials** (`./tutorials`) are collections of code and documentation which are used together to provide a step-by-step walkthrough to demonstrate the capabilities of some feature of Azure IoT Operations. These typically serve a more narrow scope than that of a tool or code sample, designed to exercise specific facets of Azure IoT Operations.

## Linting, Formatting, and Testing Requirements

Linting, formatting, and testing are not required but are highly recommended.
