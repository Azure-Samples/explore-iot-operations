# Dev Loop

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/suneetnangia/explore-iot-operations)

## Steps

1. cd `samples/auth-server-user-pass-mqtt`

    This will move you to the authentication module directory.
2. run `export IMAGE_TAG=<your_docker_registry_prefix>/auth-server-user-pass-mqtt:v0.1`

    This will configure your docker image name with registry details.

3. run ```make build```

    This will build your codebase, run unit tests and publish your docker image.

4. run ```cargo test```

    This will run the unit tests for the module, optionally.

## Deploy in K8s

1. Update `deploy/custom-user-pass-auth-server.yaml` to replace image to the container image for the module.

2. Run  `kubectl apply -f deploy/custom-user-pass-auth-server.yaml`.

    This will deploy the authentication module and its related resources

3. This step describes the credential management for this authentication module.

    1. Create Secrets Database

        The module requires secrets to be stored in [PBKDF2](https://en.wikipedia.org/wiki/PBKDF2) hash format and stored as a K8s secret.

        An example of such TOML file is provided below (clients.toml):

        ``` TOML
        # Credential #1
        # username: client1
        # password: password1
        # salt: "+H7jXzcEbq2kkyvpxtxePQ"
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
        ```

        > **Note:** you can use `tools/hash.sh` tool to create PBKDF2 encoded hash for the above file, if you need to change passwords.

    2. Attach Secrets Database

        This step creates K8s secret with a specific name `auth-server-user-pass-mqtt-server-credentials` which authentication module looks for when deployed.

        Run the following command to create the secret where `clients.tom` is the example file from step 1:

        ``` bash
        kubectl create secret generic auth-server-user-pass-mqtt-server-credentials -n azure-iot-operations --from-file=passwords.toml=./clients.toml
        ```

4. Configure custom authentication in AIO, use the instructions from [here](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication?tabs=portal#custom-authentication).
    Configure the settings as below:

    1. Endpoint: https://auth-server-user-pass-mqtt
    2. CA certificate config map: azure-iot-operations-aio-ca-trust-bundle
    3. Authentication X.509 secret reference: [leave blank]

5. Optionally, test authentication module without AIO dependencies using instructions in [debug.md](debug.md).
