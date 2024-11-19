# Azure IoT Operations state store CLI tool

The state store CLI tool can be used to manage keys and values in the Azure IoT Operations state store. The tool is a standalone self-sufficient binary application, and doesn't require the installation of additional libraries or frameworks.

Supported platforms: 

* Linux (tested on Ubuntu 24.04)
* Windows 11

> [!IMPORTANT]
> The tool is designed to run on a standalone machine with access to the Azure IoT Operations cluster. This is not designed to run on the cluster itself.

## Prerequisites

On the machine where the tool will be run, the following are required:

1. [Install kubectl](https://kubernetes.io/docs/tasks/tools/) which will be used to configure the MQTT Broker

1. Clone the `explore-iot-operations` repository, and enter the state store cli directory:

    ```shell
    git clone https://github.com/Azure-Samples/explore-iot-operations
    cd explore-iot-operations/tools/state-store-cli
    ```

1. Download the state store CLI from the [latest GitHub release](https://github.com/Azure-Samples/explore-iot-operations/releases?q=state-store-cli) and save it in the `state-store-cli` directory

1. **OPTIONAL**: If MQTT broker authentication is required, [install step](https://smallstep.com/docs/step-cli/installation/) to generate the required certificates

## Setup

### Setup with no authentication

If security is not a requirement, due to the cluster being used for non-production purposes, enabling a non-authenticated BrokerListener is the simplest approach.

1. Create a new `BrokerListener` by applying the following:

    ```shell
    kubectl apply -f yaml/listener-open.yaml
    ```

### Setup with authentication

If security is a requirement, then you will need to expose the MQTT broker using TLS and x509 certificate authentication:

1. Run `generate-credentials.sh` to create the x.509 device certificates and download the MQTT broker trust bundle:

    ```bash
    ./generate-credentials.sh
    ```

1. Inspect the output for errors and make corrections if necessary

1. Edit the following section of `yaml/listener-x509.yaml` and add the correct public DNS or IP address for your kubernetes cluster:

    ```yaml
    san:
      dns:
        - localhost
      ip:
        - 127.0.0.1
    ```

1. Create a new `BrokerListener`:

    ```shell
    kubectl apply -f yaml/listener-x509.yaml
    ```

> [!NOTE] 
> The `certs` directory will contain the following files which will be used by the state store cli tool for authenticating with the MQTT broker:
> 
>    * `broker-ca.crt` : The MQTT broker server certificate
>    * `client.crt` : The device certificate for authentication with MQTT broker
>    * `client.key` : The device private key for authentication with MQTT broker

## Usage

For accessing help directly from the console just type `statestore --help`.

```shell
$ ./statestore --help
Allows managing key/value pairs in the MQ State Store.

Usage: statestore [OPTIONS] <COMMAND>

Commands:
  get     Gets the value of an existing key
  set     Sets a key and value
  delete  Deletes an existing key and value
  help    Print this message or the help of the given subcommand(s)

Options:
  -n, --hostname <HOSTNAME>
          MQ broker hostname

          [default: localhost]

  -p, --port <PORT>
          MQ broker port number

          [default: 8883]

      --notls
          Do not use TLS for connection with MQ broker

  -T, --cafile <CAFILE>
          Trusted certificate bundle for TLS connection

  -C, --certfile <CERTFILE>
          Client authentication certificate file

  -K, --keyfile <KEYFILE>
          Client authentication private key file

  -P, --keypasswordfile <KEYPASSWORDFILE>
          Password for private key file

      --verbose
          Verbose logging (errors)

  -h, --help
          Print help (see a summary with '-h')

  -V, --version
          Print version
```

Help specific to each command can be printed through calling `statestore <command> --help`.

```shell
$ ./statestore get --help
Gets the value of an existing key

Usage: statestore get [OPTIONS] --key <KEY>

Options:
  -k, --key <KEY>
          Device State Store key name to retrieve
  -f, --valuefile <VALUEFILE>
          File where to write the key value. If not provided, the value is written to stdout
  -n, --hostname <HOSTNAME>
          MQ broker hostname [default: localhost]
  -p, --port <PORT>
          MQ broker port number [default: 8883]
      --notls
          Do not use TLS for connection with MQ broker
  -T, --cafile <CAFILE>
          Trusted certificate bundle for TLS connection
  -C, --certfile <CERTFILE>
          Client authentication certificate file
  -K, --keyfile <KEYFILE>
          Client authentication private key file
  -P, --keypasswordfile <KEYPASSWORDFILE>
          Password for private key file
      --verbose
          Verbose logging (errors)
  -h, --help
          Print help
```

## Examples

For the examples below, assume:

- The MQTT broker is named `mybroker.net`, on port `8883` or `1883`
- The MQTT brokers trusted CA certificate bundle is available locally as saved locally at `./certs/broker-ca.crt`
- Client certificates are set in the AIO MQ Broker, and saved locally at `./certs/client.crt` and `./certs/client.key`.

### X.509 authentication with TLS

To retrieve an existing key:

```shell
./statestore get -n "mybroker.net" -k "keyName1" -f "./keyValue1.txt" -T "./certs/broker-ca.crt" -C "./certs/client.crt" -K "./certs/client.key"
```

|||
|-|-|
|Outcome|Prints the value of an existing key to the console.</br>If `--valuefile` argument is provided, the value is written to the provided file if the key exists.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port, bad CA certificate).</br>- Authentication failures (bad certificates)</br>- The key does not exist.</br>- Cannot write value to file (if `--valuefile` is used).|

To set the value of a key:

```shell
./statestore set -n "mybroker.net" -k "keyName1" --value "keyValue1" -T "./certs/broker-ca.crt" -C "./certs/client.crt" -K "./certs/client.key"
```

|||
|-|-|
|Outcome|Sets the value of a key in the state store.</br>If `--valuefile` (short, `-f`) argument is provided (instead of `--value`), the value is read from the provided file.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port, bad CA certificate).</br>- Authentication failures (bad certificates)</br>- Cannot read file (if `--valuefile` is used).|

To delete an existing key:

```shell
./statestore delete -n "mybroker.net" -k "keyName1" -T "./certs/broker-ca.crt" -C "./certs/client.crt" -K "./certs/client.key"
```

|||
|-|-|
|Outcome|Deletes an existing key in the state store.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port, bad CA certificate).</br>- Authentication failures (bad certificates)</br>- Key does not exist.|

### No authentication, no TLS

> [!CAUTION]
> The use of non-secure connections with the MQTT broker is highly discouraged. The option is provided for testing purposes only and it is recommended to use secure connections in production environments.

To retrieve an existing key:

```shell
./statestore get -n "mybroker.net" -k "keyName1" -f "./keyValue1.txt" --notls
```

|||
|-|-|
|Outcome|Prints the value of an existing key to the console.</br>If `--valuefile` argument is provided, the value is written to the provided file if the key exists.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port).</br>- The key does not exist.</br>- Cannot write value to file (if `--valuefile` is used).|

To set the value of a key:

```shell
./statestore set -n "mybroker.net" -k "keyName1" --value "keyValue1" --notls
```

|||
|-|-|
|Outcome|Sets the value of a key in the state store.</br>If `--valuefile` (short, `-f`) argument is provided (instead of `--value`), the value is read from the provided file.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port).</br>- Cannot read file (if `--valuefile` is used).|

To delete an existing key:

```shell
./statestore delete -n "mybroker.net" -k "keyName1" --notls
```

|||
|-|-|
|Outcome|Deletes an existing key in the state store.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port).</br>- Key does not exist.|

## Limitations

The following features are **not** supported by the state store CLI tool:

- `vdel`, `observer` and `unobserve` operations
- SAT authentication
