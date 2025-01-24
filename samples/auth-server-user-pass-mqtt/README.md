# Azure IoT Operations (AIO) MQTT Username/Password Auth

This repo provides a secure custom username password based authentication module for MQTT service in AIO.

## Features

The authentication module provides the following top level features:

* Multiple usernames for AIO MQTT service and associated properties.
* Enforced TLS encryption between MQTT broker and the authentication module.
* PBKDF2 based password hashing and K8s secrets for secure storage.

## Getting Started

### Prerequisites

* AIO Installation

### Dev Loop

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/suneetnangia/explore-iot-operations)

#### Steps

1. cd `samples/auth-server-user-pass-mqtt`

    [This will move you to the authentication module directory.]
2. run `export IMAGE_TAG=<your_docker_registry_prefix>/auth-server-user-pass-mqtt:v0.1`

    [This will configure your docker image name with registry details]

3. run ```make build```

    [This will build your codebase along with unit tests and publish your docker image.]

4. run ```cargo test```

    [This will run the unit tests for the module.]

#### Deploy in K8s

1. Update `deploy/custom-user-pass-auth-server.yaml` to replace image to the container image for the module.

2. Run  `kubectl apply -f deploy/custom-user-pass-auth-server.yaml`.

    [This will deploy the authentication module and its related resources]

3. Create credentials database, use instructions in [credentials.md](docs/credentials.md).

4. Configure custom authentication in AIO, use the instructions from [here](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication?tabs=portal#custom-authentication).

5. Optionally, test authentication module using instructions in [k8s_debug.md](docs/k8s_debug.md).

## Resources

* [Custom Authentication in AIO](https://github.com/Azure-Samples/explore-iot-operations/tree/main/samples/auth-server-template)
* [AIO MQTT Broker Authentication](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication?tabs=portal)

## Next

1. Enable "ReAuth" MQTTv5 workflow.
2. Enable optional "MQTT broker to custom authentication module" client cert authentication.
