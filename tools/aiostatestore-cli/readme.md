# Azure IoT Operations (AIO) State Store Command-Line Interface Tool

## Description

The `aiostatestore-cli` tool can be used to manage keys and values in the AIO State Store.

## Requirements

The `aiostatestore-cli` is a standalone self-sufficient binary application, not requiring you to install any additional libraries or frameworks on the platform where the tool is run.

Supported platforms: Linux (tested on Ubuntu 24.04), Windows 11.

Requires a working AIO MQ Broker deployment.

## Setup

In the host where the Azure IoT Operations MQ Broker is deployed, run:

```shell
cd ./tools
./generate-credentials.sh
```

The copy the certificates and key in `~/aio_certs` to the same path in the machine where `aiostatestore-cli` will be run.

## Usage

For the examples below please assume:
- The target AIO MQ Broker is hosted at `myaiomqbroker.net`, with ports 8883 and 1883 open.
- The MQ Broker trusted CA certificate bundle is saved locally at `~/aio_certs/root_ca.crt`
- Client certificates are set in the AIO MQ Broker, and saved locally at `~/aio_certs/client.crt` and `~/aio_certs/client.key`.

### Access the built-in help documentation

For accessing help directly from the console just type `aiostatestore-cli --help`.

```shell
user@ubuntu2404:~$ ./aiostatestore-cli --help
Allows managing key/value pairs in the MQ State Store.

Usage: aiostatestore-cli [OPTIONS] <COMMAND>

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
user@ubuntu2404:~$
```

Help specific to each command can be printed through calling `aiostatestore-cli <command> --help`.

```shell
user@ubuntu2404:~$ ./aiostatestore-cli get --help
Gets the value of an existing key

Usage: aiostatestore-cli get [OPTIONS] --key <KEY>

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
user@ubuntu2404:~$
```

### Certificate-Authenticated Client with TLS Connection

To retrieve an existing key:

```shell
./aiostatestore-cli get -n "myaiomqbroker.net" -k "keyName1" -f "./keyValue1.txt" -T "~/certs/broker-ca.crt" -C "~/certs/client.crt" -K "~/certs/client.key"
```

|||
|-|-|
|Outcome|Prints the value of an existing key to the console.</br>If `--valuefile` argument is provided, the value is written to the provided file if the key exists.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port, bad CA certificate).</br>- Authentication failures (bad certificates)</br>- The key does not exist.</br>- Cannot write value to file (if `--valuefile` is used).|

To set the value of a key:

```shell
./aiostatestore-cli set -n "myaiomqbroker.net" -k "keyName1" --value "keyValue1" -T "~/certs/broker-ca.crt" -C "~/certs/client.crt" -K "~/certs/client.key"
```

|||
|-|-|
|Outcome|Sets the value of a key in the state store.</br>If `--valuefile` (short, `-f`) argument is provided (instead of `--value`), the value is read from the provided file.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port, bad CA certificate).</br>- Authentication failures (bad certificates)</br>- Cannot read file (if `--valuefile` is used).|

To delete an existing key:

```shell
./aiostatestore-cli delete -n "myaiomqbroker.net" -k "keyName1" -T "~/certs/broker-ca.crt" -C "~/certs/client.crt" -K "~/certs/client.key"
```

|||
|-|-|
|Outcome|Deletes an existing key in the state store.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port, bad CA certificate).</br>- Authentication failures (bad certificates)</br>- Key does not exist.|


### Annonymous Client with Plain TCP Connection (no TLS)

> **Disclaimer:**</br>
> The use non-secure connections with the AIO MQ Broker is highly discouraged.</br>
> That option is provided in `aiostatestore-cli` for testing purposes only.</br>
> Our recommendation is to not use unsecure (non-TLS) connections in production environments. 

To retrieve an existing key:

```shell
./aiostatestore-cli get -n "myaiomqbroker.net" -k "keyName1" -f "./keyValue1.txt" --notls
```

|||
|-|-|
|Outcome|Prints the value of an existing key to the console.</br>If `--valuefile` argument is provided, the value is written to the provided file if the key exists.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port).</br>- The key does not exist.</br>- Cannot write value to file (if `--valuefile` is used).|

To set the value of a key:

```shell
./aiostatestore-cli set -n "myaiomqbroker.net" -k "keyName1" --value "keyValue1" --notls
```

|||
|-|-|
|Outcome|Sets the value of a key in the state store.</br>If `--valuefile` (short, `-f`) argument is provided (instead of `--value`), the value is read from the provided file.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port).</br>- Cannot read file (if `--valuefile` is used).|

To delete an existing key:

```shell
./aiostatestore-cli delete -n "myaiomqbroker.net" -k "keyName1" --notls
```

|||
|-|-|
|Outcome|Deletes an existing key in the state store.|
|Return|Zero (0) on success, non-zero on error.|
|Possible errors|- Not able to connect (no internet, bad hostname and/or port).</br>- Key does not exist.|

## Limitations

The following features are not currently supported by `aiostatestore-cli`:

- The following AIO MQ State Store operations are not supported: vdel, observe/unobserve.
- No username/password authentication.
- No SAT authentication. 

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
