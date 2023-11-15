# Explore IoT Operations Organization

## Structure

Explore IoT Operations is a collection of tools and samples for customers of Azure IoT Operations. To keep the project understandable and extensible to future additions, the following conventions should be followed for repository structure.

```
├── lib/
│   ├── library1/
│   ├── ...
│   ├── libraryN/
├── samples/
│   ├── sample1/
│   ├── ...
│   ├── sampleN/
├── scripts/
├── tutorials/
└── README.md
```

**Libraries** (`./lib`) are shared between multiple tools or samples.

**Samples** (`./samples`) are tools or code samples which can be written in any language. They should be given a descriptive name which adequately describes their purpose, and should include some level of documentation regarding their usage.

**Scripts** (`./scripts`) are bash scripts smaller than a tool or sample which are in some way used for setup.

**Tutorials** (`./tutorials`) are collections of code and documentation which are used together to provide a step-by-step walkthrough to demonstrate the capabilities of some feature of Azure IoT Operations. These typically serve a more narrow scope than that of a tool or code sample, designed to exercise specific facets of Azure IoT Operations.

## Linting, Formatting, and Testing Requirements

Linting, formatting, and testing are not required but are highly recommended. The mage library under `./lib/mage` is provided for golang projects and offers some basic commands for linting, formatting, building, testing, and assuring test coverage bars. Comments describe each function within the library. See `./samples/industrial-data-simulator/mage.go` for an example of how this library is used.
