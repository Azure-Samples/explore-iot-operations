# Credential Management

This section describes the credential management for this authentication module.

1. Create Secrets Database

    The module requires secrets to be stored in [PBKDF2](https://en.wikipedia.org/wiki/PBKDF2) hash format and stored as a K8s secret.

    An example of such TOML file is provided below (clients.toml):

    ``` TOML
    # Credential #1
    # username: client1
    # password: password
    # salt: "HqJwOCHweNk1pLryiu3RsA"
    [client1]
    password = "$pbkdf2-sha512$i=100000,l=64$HqJwOCHweNk1pLryiu3RsA$KVSvxKYcibIG5S5n55RvxKRTdAAfCUtBJoy5IuFzdSZyzkwvUcU+FPawEWFPn+06JyZsndfRTfpiEh+2eSJLkg"

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
    site = "site1"
    ```

    > **Note:** We currently do not support PBKDF2 encoding of password using built-in az commands, this will be added soon. Until then use the following command to create the hash.

    TODO: add openssl cmd to hash the password here.

2. Attach Secrets Database

    This step creates K8s secret with a specific name `auth-server-user-pass-mqtt-server-credentials` which authentication module looks for when deployed.

    Run the following command to create the secret where `clients.tom` is the example file from step 1:

    ``` bash
   kubectl create secret generic auth-server-user-pass-mqtt-server-credentials -n azure-iot-operations --from-file=passwords.toml=./clients.toml
    ```
