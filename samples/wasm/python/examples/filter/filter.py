import json
from filter_impl import exports
from filter_impl import imports
from filter_impl.imports import types

class Filter(exports.Filter):
    def init(self, configuration) -> bool:
        imports.logger.log(imports.logger.Level.INFO, "temperature-filter", "Init invoked")
        # Set default threshold from configuration
        self.temperature_threshold = 20.0  # Default threshold in Celsius
        
        if hasattr(configuration, 'properties'):
            for key, param in configuration.properties.items():
                if key == "temperature_threshold":
                    try:
                        self.temperature_threshold = float(param.name)
                        imports.logger.log(
                            imports.logger.Level.INFO, 
                            "temperature-filter", 
                            f"Set temperature threshold to {self.temperature_threshold}°C"
                        )
                    except ValueError:
                        imports.logger.log(
                            imports.logger.Level.WARN, 
                            "temperature-filter", 
                            f"Invalid threshold value: {param.name}, using default"
                        )
        
        return True

    def process(self, message: types.DataModel) -> bool:
        """
        Filter temperature data based on threshold.
        Returns True to pass the message through, False to filter it out.
        """
        try:
            if not isinstance(message, types.DataModel_Message):
                # Pass through non-message data
                return True

            # Extract and decode the payload
            payload_variant = message.value.payload

            if isinstance(payload_variant, types.BufferOrBytes_Buffer):
                buffer = payload_variant.value
                payload = buffer.read()
                imports.logger.log(imports.logger.Level.INFO, "temperature-filter", "Reading payload from Buffer")
            elif isinstance(payload_variant, types.BufferOrBytes_Bytes):
                payload = payload_variant.value
                imports.logger.log(imports.logger.Level.INFO, "temperature-filter", "Reading payload from Bytes")
            else:
                imports.logger.log(
                    imports.logger.Level.WARN,
                    "temperature-filter",
                    "Unexpected payload type"
                )
                return True

            decoded = payload.decode("utf-8")

            # Parse the JSON data
            json_data = json.loads(decoded)

            # Check if this is temperature data
            if "temperature" in json_data and "value" in json_data["temperature"]:
                temp_value = json_data["temperature"]["value"]
                unit = json_data["temperature"].get("unit", "C")
                
                # Convert to Celsius if needed
                if unit.upper() == "F":
                    temp_celsius = (temp_value - 32) * 5.0 / 9.0
                else:
                    temp_celsius = temp_value
                
                # Apply threshold filter
                pass_filter = temp_celsius >= self.temperature_threshold
                
                imports.logger.log(
                    imports.logger.Level.DEBUG,
                    "temperature-filter",
                    f"Temperature: {temp_celsius}°C, Threshold: {self.temperature_threshold}°C, Pass: {pass_filter}"
                )
                
                return pass_filter
            else:
                # Not temperature data, pass through
                return True
                
        except Exception as e:
            imports.logger.log(
                imports.logger.Level.ERROR,
                "temperature-filter",
                f"Error processing message: {str(e)}"
            )
            # Pass through on error to avoid breaking the pipeline
            return True
