# User properties to payload

This sample embeds MQTT user properties into the JSON payload so they are
preserved when the connector's `forward_data` does not propagate
`custom_user_data` as outbound MQTT user properties.

This WASM module expects a JSON object payload. It fails if the payload is not valid JSON
or is not a JSON object at the top level.

The resulting payload is a JSON object with the original fields plus a
`_user_properties` key that contains the MQTT user properties as a JSON object.
User properties with duplicate keys are collected into a JSON array for that key.

## Example

Input payload:
```json
{"temperature": 42}
```

Input user properties:
```
deviceId = sensor-01
region   = us-west
```

Output payload:
```json
{"temperature": 42, "_user_properties": {"deviceId": "sensor-01", "region": "us-west"}}
```
