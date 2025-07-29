# Sample WASM modules

WebAssembly example test modules.

Following are the example modules that can be used in the graph. See the [example graph](../docs/example-graph.md) for a complete example.

## collection

1. **collection/accumulate**: accumulate all sensor data, including temperature, humidity and object detection result.

## enrichment

1. **enrichment/map**: enrich existing temperature by checking and adding/removing over temperature flag status.

## humidity

1. **humidity/accumulate**: accumulate and process all incoming humidity data within a specific time interval.

## snapshot

1. **snapshot/branch**: check and determine current data to be processed through snapshot or non-snapshot routine.
2. **snapshot/map**: convert a single snapshot to a detected object with the highest probability.\
3. **snapshot/accumulate**: accumulate and process all incoming snapshot data within a specific time interval.

## temperature

1. **temperature/map**: convert temperature data value from Fahrenheit to Celsius if necessary.\
2. **temperature/branch**: check and determine current data to be processed through temperature or humidity routine.
3. **temperature/filter**: filter temperature data value which exceeds the pre-configured limitations.\
4. **temperature/accumulate**: accumulate and process all incoming temperature data within a specific time interval.

## window

1. **window/delay**: delay all incoming data to a specific time interval.

## format

1. **format/map**: decode and rescale the snapshot image to the specific format required by snapshot object detection.
