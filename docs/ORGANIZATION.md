# Toolbox Organization

## Structure

The AIO toolbox is a collection of several tools for customers of AIO. To keep the project understandable and extensible to future additions, the following conventions should be followed for repository structure.

```
├── lib
│   ├── library1
│   ├── ...
│   ├── libraryN
├── samples
│   ├── tool1
│   │   ├── config.yml
│   │   ├── config.json
│   ├── ...
│   ├── toolN
├── tools
│   ├── tool1
│   │   ├── cmd
│   │   │   ├── main.go
│   │   ├── pkg
│   │   │   ├── pkg1
│   ├── ...
│   ├── toolN
├── docker
│   ├── tool1
│   │   ├── Dockerfile
│   ├── ...
│   ├── toolN
├── go.mod
├── go.sum
├── magefile.go
└── README.md
```

__Libraries__ which are shared between multiple tools should be stored in the lib directory. This library can be incorporated into projects beyond AIO tools and such documentation will be available on the _go.dev_ documentation site.

__Samples__ are configuration files which have been created for specific sample usages of a tool. Multiple configuration files can live in each sample folder for different samples which utilize the same tool.

__Tools__ are AIO specific tools which may have their own internal packages stored within the pkg folder. Other top-level folders in each tool are allowed, though it is recommended to minimize the number of top-level folders. Each tool must also have its own cmd directory where the entrypoint is located.

__Dockerfiles__ for relavent docker images are stored for each tool under the docker directory. They are siloed into their own directories for each tool.

__Mage Commands__ are located within the magefile.go. Mage commands should be written in such a way that they apply to any given tool based on a parameter. Mage commands should not be targeted at a specific tool itself. If such a command is required, a magefile within the tool directory should be produced.

## Linting & Formatting Requirements

Linting and formatting rules are applied to all tools and libraries based on a linting configuration set up and applied via mage commands.

## Example Tool

Please view the example tool in `tools/example` for an example of how to contribute a new tool to the AIO toolbox.

_Note_: tools can be written in any language including minimal tools such as bash scripts. The tools are written in golang in this document for example purposes.