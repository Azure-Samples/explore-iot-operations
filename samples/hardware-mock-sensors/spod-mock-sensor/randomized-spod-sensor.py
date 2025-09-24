import json
import random
import time
import os
import requests
import logging

from datetime import datetime, timezone
from datetime import timedelta
from dateutil.parser import parse
from flask import Flask, jsonify, request
app = Flask(__name__)

logging.basicConfig(level=logging.INFO)

# Define ranges for each measurement and field
# TO:DO: update all measurement types with realistic ranges for each
RANGES = {
    'ppb':   (550, 700),    # ppb
    'pid':   (550, 700),    # ppb
    'temp':  (22, 25),      # Celsius
    'humid': (32, 35),      # percent
    'pres':  (552, 1084),   # mBar
    'wspd':  (4, 7),        # mph
    'wdir':  (292, 295),    # degrees
    'batt':  (0, 100),      # volt
    'chrg':  (0, 100),      # mA
    'run':   (0, 100),      # mA
    'tsen1': (0, 100),
    'heat1': (0, 100),
    'tset1': (0, 100),
    'sd':    (0, 100),
    'tcrh':  (0, 100),
    'r232':  (0, 100),
    'brdv':  (0, 100),
    'fwv':   (0, 100),
    'misc':  (0, 100),
    'zero1': (0, 100),
    'span1': (0, 100),
    'ofs1':  (0, 100),
    'slp1':  (0, 100),
    'lat':   (-90, 90),
    'lon':   (-180, 180),
}

DEVICE_IDS = ["SPOD01433", "SPOD01434", "SPOD01435"]

class SpodData:
    def __init__(self):
        self.data = json.load(open('SPOD.json'))

    def get_dataset(self):
        return self.data

def generate_timestamp():
    return datetime.now().strftime('%Y-%m-%dT%H:%M:%S')

@app.route('/spod/input', methods=['GET'])
def get_spod_data():
    data = spod_data.get_dataset()

    logging.info("Generating SPOD data")

    for field in data['iodb']:
        range_min, range_max = RANGES[field]
        data['iodb'][field] = round(random.uniform(range_min, range_max), 1)

    data['time'] = generate_timestamp()
    data['deviceId'] = random.choice(DEVICE_IDS)
    
    logging.info("SPOD data sending - time: %s", data['time'])

    response = jsonify(data)
    
    # check if in the parameters come uuid, if yes, put the whole response in a html body
    # this is closer to what the spod actually returns like
    # for some reason the spod sensor, does not comply with headers like Accept and Content-Type
    if 'uuid' in request.args:
        return "<!DOCTYPE HTML>\n<html>" + response.get_data(as_text=True) + "</html>"
    
    return response

if __name__ == '__main__':
    spod_data = SpodData()
    app.run(host='0.0.0.0', port=8080)