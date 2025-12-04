import branch_impl;
import payload
from branch_impl import exports
from branch_impl import imports
from branch_impl.imports import types
from payload import Payload


def to_bytes(payload_variant):
    if isinstance(payload_variant, types.BufferOrBytes_Buffer):
        return payload_variant.value.read()
    if isinstance(payload_variant, types.BufferOrBytes_Bytes):
        return payload_variant.value
    raise ValueError("Unexpected payload type")

class Branch(exports.Branch):
    def init(self, configuration) -> bool:
        imports.logger.log(imports.logger.Level.INFO, "module3/branch", "Init invoked")
        return True

    def process(self, timestamp: int, input: types.DataModel) -> int:
        imports.logger.log(imports.logger.Level.INFO, "module3/branch", "processing from python")

        if not isinstance(input, types.DataModel_Message):
            raise ValueError("Unexpected input type: Expected DataModel_Message")

        message = input.value
        payload = to_bytes(message.payload)
        decoded = payload.decode("utf-8")
        p = Payload(decoded)

        if p.is_temperature():
            imports.logger.log(imports.logger.Level.INFO, "module3/branch", "temperature")
            return 0

        imports.logger.log(imports.logger.Level.INFO, "module3/branch", "humidity")
        return 1
