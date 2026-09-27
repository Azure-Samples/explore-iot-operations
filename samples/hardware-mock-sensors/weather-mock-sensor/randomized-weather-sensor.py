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

# Define ranges for each measurement and field - this will be for fields in the metric system in the 'metric' array
# TO:DO: update all measurement types under device_data with realistic ranges, rest of fields are generated between 0-100
RANGES = {
    'atmp': {
        'tic': (22, 25),    # Celsius
        'tia': (22, 25),
        'tdh': (22, 25),
        'tih': (22, 25),
        'tdl': (22, 25),
        'til': (22, 25)
    },
    'rh': {
        'ric': (32, 35),    # percent
        'ria': (32, 35),
        'rdh': (32, 35),
        'rih': (32, 35),
        'rdl': (32, 35),
        'ril': (32, 35)
    },
    'wnd': {
        'wic': (6.4, 11.3), # km/hr (about 4-7 mph)
        'wict': (292, 295), # degrees
        'wia': (6.4, 11.3),
        'wdh': (6.4, 11.3),
        'wdht': (292, 295),
        'wih': (6.4, 11.3),
        'wiht': (292, 295)
    },
    'bp': {
        'bic': (552, 1084), # mBar
        'bia': (552, 1084),
        'bdh': (552, 1084),
        'bih': (552, 1084),
        'bdl': (552, 1084),
        'bil': (552, 1084)
    },
}

class WeatherData:
    def __init__(self):
        self.data = json.load(open('weather-station-rainwise.json'))
        self.event_id = random.randint(0, 500)

    def get_dataset(self):
        return self.data

# Placeholder to generate random data
def generate_random_data():
    return round(random.uniform(0, 100), 1)

def generate_data(field, measurement):
    if measurement not in RANGES:
        return generate_random_data()
    else:
        range_min, range_max = RANGES[measurement][field]
        value = round(random.uniform(range_min, range_max), 1)
        return value

def convert_to_us(value, measurement, field):
    
    # Convert to Fahrenheit
    if measurement in ['atmp', 'tmp1', 'tmp2', 'itmp']:
        return round((value * 9/5) + 32, 1)
    
    # Convert from kmh to mph
    elif measurement == 'wnd' and field in ['wic', 'wia', 'wdh', 'wih']:
        return round(value * 0.621371, 1)
    
    # Convert from mbar to inHg
    elif measurement == 'bp':
        return round(value * 0.0295301, 1)

    return value

def generate_timestamp():
    return datetime.now().strftime("%Y/%m/%d %H:%M:%S")

@app.route('/healthcheck', methods=['GET'])
def healthcheck():
    status = request.args.get('status')
    if status:
        if status == "random":
            if random.choice(["OK", "OFF"]) == "OFF":
                return jsonify({"status": "OFFLINE"}), 500
        elif status == "off":
            return jsonify({"status": "OFFLINE"}), 500
        
    data = {
        "status": "OK",
        "version": "1.0",
        "details": {
            "temperature": "OK",
            "humidity": "OK",
            "wind": "OK",
            "barometric_pressure": "OK"
        }
    }

    return jsonify(data)

@app.route('/weather/input', methods=['GET'])
def get_weather_data():
    data = weather_data.get_dataset()

    logging.info("Generating weather data")
                
    # Loop over weather measurements
    for measurement in data['metric']:
        for field in data['metric'][measurement]:
            value = generate_data(field, measurement)
            data['metric'][measurement][field] = value
            data['us'][measurement][field] = convert_to_us(value, measurement, field)
                
    data['time'] = generate_timestamp()
            
    logging.info("Weather data sending - timestamp: %s", data['time'])

    return jsonify(data)

if __name__ == '__main__':
    weather_data = WeatherData()
    app.run(host='0.0.0.0', port=8080)