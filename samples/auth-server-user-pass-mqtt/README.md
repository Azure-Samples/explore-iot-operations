# Azure IoT Operations (AIO) MQTT Username/Password Auth

This module provides a custom username password based authentication for MQTT service in AIO.

> **Caveat:** currently, credentials are stored in a K8s secret without any encryption, this must be addressed if this sample is used in production.

## Features

The authentication module provides the following top level features:

* Multiple usernames for AIO MQTT service and associated properties.
* Enforced TLS encryption between MQTT broker and the authentication module.
* PBKDF2 based password hashing and K8s secrets for secure storage.

## Getting Started

### Prerequisites

* AIO Installation

### Deploy in AIO Environment

A pre-built image of the module is available with the tag `ghcr.io/azure-samples/explore-iot-operations/auth-server-user-pass-mqtt:v0.1`.

You can deploy this module by running the following cmds in your AIO/K8s environment:

1. Create a sample credential database:
    > **WARNING** DO NOT USE THESE CREDENTIALS IN PRODUCTION, THESE CREDENTIALS ARE FOR TESTING PURPOSES ONLY IN LOCAL ENVIRONMENTS

    ```bash
        kubectl create secret generic auth-server-user-pass-mqtt-server-credentials -n azure-iot-operations --from-literal=passwords.toml='
        # Credential #1
        # username: client1
        # password: password1
        # salt: "64$EnyzbHpiNqeTeM9Gl3rjWQ"
        [client1]
        password = "$pbkdf2-sha512$i=100000,l=64$EnyzbHpiNqeTeM9Gl3rjWQ$Qc3MqYZ3Q49kz3Uh1Ia4A5UMDMlhxujgNjNYgpgVDDaiq13DP5IEM7gA7MbsU70RTGn5qHU9uis79LkLV5wkAg"

        [client1.attributes]
        floor = "floor1"
        site = "site1"

        # Credential #2
        # username: client2
        # password: password2
        # salt: "+H7jXzcEbq2kkyvpxtxePQ"
        [client2]
        password = "$pbkdf2-sha512$i=100000,l=64$+H7jXzcEbq2kkyvpxtxePQ$jTzW6fSesiuNRLMIkDDAzBEILk7iyyDZ3rjlEwQap4UJP4TaCR+EXQXNukO7qNJWlPPP8leNnJDCBgX/255Ezw"

        [client2.attributes]
        floor = "floor2"
        site = "site2"
        '
    ```

2. Deploy authentication module and its related resources:

    ```kubectl apply -f ./deploy/custom-user-pass-auth-server.yaml```

3. Configure AIO MQTT Authentication

    Use the instructions [here](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication?tabs=portal#custom-authentication) for custom authentication method and configure the settings as below:

    1. Endpoint: `https://auth-server-user-pass-mqtt`
    2. CA certificate config map: `azure-iot-operations-aio-ca-trust-bundle`
    3. Authentication X.509 secret reference: `auth-server-user-pass-mqtt-client-cert`

    >**NOTE:** please ensure `Custom` auth type is placed at the end of the authentication methods list in the authentication policy. This is important as `Custom` auth type does not defer to other auth methods in the chain.

4. Verify Username/password Authentication

    Use the instructions [here](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-test-connection?tabs=portal#connect-to-the-default-listener-inside-the-cluster) and to create the MQTT testing pod and open a shell inside. Once inside the shell, run the following cmd:

    `mosquitto_pub -i "user-pass-test-client"  --host aio-broker --port 18883 --message "hello" --topic "world" --debug --cafile /var/run/certs/ca.crt -u "client1" -P "password1"`

## Dev Loop

Please refer to [this](./docs/develoop.md) document for details.

## Upcoming Features

1. Enable "ReAuth" MQTTv5 workflow.
2. Enable authentication expiry configuration and response.

## Resources

* [Custom Authentication in AIO](https://github.com/Azure-Samples/explore-iot-operations/tree/main/samples/auth-server-template)
* [AIO MQTT Broker Authentication](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication?tabs=portal)
