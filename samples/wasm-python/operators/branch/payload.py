import json

class Payload:
    def __init__(self, j):
        self.__dict__ = json.loads(j)

    def is_temperature(self):
        return 'temperature' in self.__dict__

    def is_humidity(self):
        return 'humidity' in self.__dict__
