import json
from map_impl import exports
from map_impl import imports
from map_impl.imports import types

class Map(exports.Map):
    def init(self, configuration) -> bool:
        imports.logger.log(imports.logger.Level.INFO, "module4/map", "Init invoked")
        return True

    def process(self, message: types.DataModel) -> types.DataModel:
        # TODO: implement custom logic for map operator
        imports.logger.log(imports.logger.Level.INFO, "module4/map", "processing from python")

        # Ensure the input is of the expected type
        if not isinstance(message, types.DataModel_Message):
            raise ValueError("Unexpected input type: Expected DataModel_Message")

        # Extract and decode the payload
        payload_variant = message.value.payload
        if isinstance(payload_variant, types.BufferOrBytes_Buffer):
            # It's a Buffer handle - read from host
            imports.logger.log(imports.logger.Level.INFO, "module4/map", "Reading payload from Buffer")
            payload = payload_variant.value.read()
        elif isinstance(payload_variant, types.BufferOrBytes_Bytes):
            # It's already bytes
            imports.logger.log(imports.logger.Level.INFO, "module4/map", "Reading payload from Bytes")
            payload = payload_variant.value
        else:
            raise ValueError("Unexpected payload type")

        decoded = payload.decode("utf-8")

        # Parse the JSON data
        json_data = json.loads(decoded)

        # Check and update the temperature value
        if "temperature" in json_data and "value" in json_data["temperature"]:
            temp_f = json_data["temperature"]["value"]
            if isinstance(temp_f, int):
                # Convert Fahrenheit to Celsius
                temp_c = round((temp_f - 32) * 5.0 / 9.0)

                # Update the JSON data
                json_data["temperature"]["value"] = temp_c
                json_data["temperature"]["unit"] = "C"

                # Serialize the updated JSON back to bytes
                updated_payload = json.dumps(json_data).encode("utf-8")

                # Update the message payload
                message.value.payload = types.BufferOrBytes_Bytes(value=updated_payload)

        return message