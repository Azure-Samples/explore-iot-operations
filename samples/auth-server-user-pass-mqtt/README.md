# Azure IoT Operations (AIO) MQTT Username/Password Auth

A custom username password based authentication module for the MQTT service in AIO.

## Features

This authentication module provides the following features:

* Multiple usernames for AIO MQTT service
* Enforced end to end TLS encryption

## Getting Started

### Prerequisites

* AIO Installation

### Quickstart

1. git clone [repository clone url]
2. cd [repository name]
3. run ```make build```

### Debug

Please refer to [debugging document](docs/debug.md) for details.

#### credentials.toml

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

To encode the password using PBKDF2, download and install [az iot ops](https://learn.microsoft.com/en-us/cli/azure/iot/ops?view=azure-cli-latest) and run the following cmd

```<add feature in az iot ops to create PBKDF2 encoded password for ease, if this feature is not already available>```

## Resources

* [Custom Authentication in AIO](https://github.com/Azure-Samples/explore-iot-operations/tree/main/samples/auth-server-template)
* [AIO MQTT Broker Authentication](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication?tabs=portal)
* ...

## Dependencies

* Container registry and sample authentication server image

## TODOs

1. ```az iot ops``` feature to create PBKDF2 encoded password.
2. Add unit tests in Rust.
3. Enable client cert authentication.
4. ...
