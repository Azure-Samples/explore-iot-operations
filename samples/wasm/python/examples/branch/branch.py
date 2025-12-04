import branch_impl;
import payload
from branch_impl import exports
from branch_impl import imports
from branch_impl.imports import types
from payload import Payload

class Branch(exports.Branch):
    def init(self, configuration) -> bool:
        imports.logger.log(imports.logger.Level.INFO, "module3/branch", "Init invoked")
        return True

    def process(self, timestamp: int, input: types.DataModel) -> int:
        imports.logger.log(imports.logger.Level.INFO, "module3/branch", "processing from python")

        if isinstance(input, types.DataModel_Message):

            message = input.value
            payload_variant = message.payload

            if isinstance(payload_variant, types.BufferOrBytes_Buffer):
                buffer = payload_variant.value
                payload = buffer.read()
                imports.logger.log(imports.logger.Level.INFO, "module3/branch", "Reading payload from Buffer")
            elif isinstance(payload_variant, types.BufferOrBytes_Bytes):
                payload = payload_variant.value
                imports.logger.log(imports.logger.Level.INFO, "module3/branch", "Reading payload from Bytes")
            else:
                imports.logger.log(imports.logger.Level.INFO, "module3/branch", "payload type not expected")
                return 2

            decoded = payload.decode("utf-8")
            p = Payload(decoded)

            if p.is_temperature():
                imports.logger.log(imports.logger.Level.INFO, "module3/branch", "temperature")
                return 0
            else:
                imports.logger.log(imports.logger.Level.INFO, "module3/branch", "humidity")
                return 1

        imports.logger.log(imports.logger.Level.INFO, "module3/branch", "not mqtt message")
        return 2
