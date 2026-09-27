import json
import random
import os
import requests
import logging

from flask import Flask, jsonify
app = Flask(__name__)

logging.basicConfig(level=logging.INFO)

@app.route('/weather/invalid-input', methods=['GET'])
def get_invalid_weather_data():
    ERROR_TYPE = int(os.environ.get('ERROR_TYPE', random.choice([1, 2, 3, 4])))
    if ERROR_TYPE == 1:
        data = json.load(open('weather-data/missing-key-field.json'))
        logging.info("Sending data with missing key field - us.atmp.tic")
    elif ERROR_TYPE == 2:
        data = json.load(open('weather-data/incorrect-data-type.json'))
        logging.info("Sending data with erroneous data type - us.atmp.tic set to 'Hello world'")
    elif ERROR_TYPE == 3:
        data = json.load(open('weather-data/out-of-range.json'))
        logging.info("Sending data with out of range us.atmp.tic")
    elif ERROR_TYPE == 4:
        data = json.load(open('weather-data/cannot-parse.json'))
        logging.info("Sending JSON that cannot be parsed")
    else:
        raise ValueError("No valid error type specified")

    return jsonify(data)

@app.route('/spod/invalid-input', methods=['GET'])
def get_invalid_spod_data():
    ERROR_TYPE = int(os.environ.get('ERROR_TYPE', random.choice([1, 2, 3, 4])))
    if ERROR_TYPE == 1:
        data = json.load(open('spod-data/missing-key-field.json'))
        logging.info("Sending data with missing key field - us.atmp.tic")
    elif ERROR_TYPE == 2:
        data = json.load(open('spod-data/incorrect-data-type.json'))
        logging.info("Sending data with erroneous data type - us.atmp.tic set to 'Hello world'")
    elif ERROR_TYPE == 3:
        data = json.load(open('spod-data/out-of-range.json'))
        logging.info("Sending data with out of range us.atmp.tic")
    elif ERROR_TYPE == 4:
        data = json.load(open('spod-data/cannot-parse.json'))
        logging.info("Sending JSON that cannot be parsed")
    else:
        raise ValueError("No valid error type specified")

    return jsonify(data)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)