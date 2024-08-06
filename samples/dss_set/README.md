# DSS Set Tool Instructions

## Overview
The `dss_set` tool is used to ingest sample reference data into Azure IoT MQ's distributed state store (DSS) that can be used to contextualize data within data flows.

## Download the Tool
Download the `dss_set` tool from the explore-iot-operations samples repository:

[Download `dss_set` Tool](https://github.com/Azure-Samples/explore-iot-operations/tree/main/samples/dss_set/bin/x86_linux)

The tool works on x86 and Linux.

## Running the Tool
After downloading the tool to the desired directory, the tool can be run using the following command:

```bash
./dss_set --key key1 --file "dss_reference_data.json" --address localhost --port 1883

### Notes and Parameters

1. A file with the proper format is available in the file [`dss_reference_data.json`](https://github.com/Azure-Samples/explore-iot-operations/blob/main/samples/dss_set/dss_reference_data.json).
2. MQ is available on localhost and port 1883. Change the address to reflect the current deployment.
3. The contextualization dataset will be used by the key `key1`.

