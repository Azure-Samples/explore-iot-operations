import random
import time
import os
import logging
from flask import Flask, Response, request
from flask_cors import CORS, cross_origin

logging.basicConfig(level=logging.DEBUG)

INTERVAL = int(os.environ.get('INTERVAL', 120))

app = Flask(__name__)
CORS(app)

@app.route('/dcam-events', methods=['GET'])
@cross_origin()
def events():
    last_event_id = request.args.get('last_received')
    if last_event_id is not None:
        registry.event_id = int(last_event_id)
    def generate():
            camera_ids = [1, 2, 3]
            def generate_heartbeat():
                timestamp = int(time.time() * 1000)
                yield f'event: HEARTBEAT\ndata: {{"type":"HEARTBEAT", "timestamp":{timestamp}}}\n\n'
                
            def generate_alert():
                timestamp = int(time.time() * 1000)
                registry.event_id += 1
                yield f'event: ALERT\ndata: {{"type":"ALERT", "timestamp":{timestamp}, "message":"leak", "event_id":{registry.event_id}}}\n\n'

            def generate_alert_dlqc():
                timestamp = int(time.time() * 1000)
                registry.event_id += 1
                yield f'event: ALERT_DLQC\ndata: {{"type":"ALERT_DLQC", "timestamp":{timestamp}, "message":"leak", "event_id":{registry.event_id}, "camera_id": {random.choice(camera_ids)}, "leak_location":{{"longitude":{random.uniform(-180, 180)}, "latitude":{random.uniform(-90, 90)}}}, "camera_location":{{"longitude":{random.uniform(-180, 180)}, "latitude":{random.uniform(-90, 90)}}}, "flow_rate":{random.uniform(0, 100)}, "unit":"g/s", "mass":{random.uniform(0, 10)}, "mass_unit":"kg", "confidence_level":{random.randint(2, 100)}, "camera_orientation":{random.randint(0, 360)}, "depression_angle":{random.randint(0, 90)}, "wind_speed":{random.uniform(0, 50)}, "wind_speed_unit":"m/h", "wind_direction":{random.randint(0, 360)}, "temperature":{random.uniform(-50, 50)}, "temperature_unit":"F", "humidity":{random.randint(0, 100)}}}\n\n'

            while True:
                yield from generate_heartbeat()
                
                for _ in range(2):
                    event_probability = random.randint(1, 10)
                    
                    # Generate alerts with 50% probability if alert generation is enabled
                    if event_probability < 5 and registry.is_alert_enabled:
                        # Generate alerts based on current analytics state
                        if registry.is_analytics_enabled:
                            yield from generate_alert_dlqc()
                        else:
                            yield from generate_alert()
                        
                    # This is in a loop of 2 so the heartbeat will be sent every 10 seconds
                    time.sleep(INTERVAL/2)
                        
    return Response(generate(), content_type='text/event-stream')

@app.route('/get-snapshot', methods=['GET'])
@cross_origin()
def get_snapshot_camera_event():
    camera_id = request.args.get('cameraId')
    event_id = request.args.get('eventId')
    logging.info(f'Finding a snapshot for:\nCamera ID: {camera_id}, Event ID: {event_id}')

    def generate():
        random_number = random.randint(1, 7)
        image_path = f"snapshots/snap{random_number}.jpeg"
        with open(image_path, "rb") as image_file:
            yield image_file.read()
                       
    return Response(generate(), content_type='image/png')

@app.route('/start-alert', methods=['GET'])
@cross_origin()
def start_alert():
    registry.is_alert_enabled = True
    logging.info("Alert generation ENABLED")
    return {"status": "success", "message": "Alert generation enabled", "alert_status": True}

@app.route('/stop-alert', methods=['GET'])
@cross_origin()
def stop_alert():
    registry.is_alert_enabled = False
    logging.info("Alert generation DISABLED")
    return {"status": "success", "message": "Alert generation disabled", "alert_status": False}

@app.route('/set-analytics-enabled', methods=['GET'])
@cross_origin()
def set_analytics_enabled():
    registry.is_analytics_enabled = True
    logging.info("Analytics state set to ENABLED")
    return {"status": "success", "message": "Analytics state set to enabled", "analytics_enabled": True}

@app.route('/set-analytics-disabled', methods=['GET'])
@cross_origin()
def set_analytics_disabled():
    registry.is_analytics_enabled = False
    logging.info("Analytics state set to DISABLED")
    return {"status": "success", "message": "Analytics state set to disabled", "analytics_enabled": False}

@app.route('/healthcheck', methods=['GET'])
@cross_origin()
def healthcheck():
    return {
        "status": "healthy",
        "alert_enabled": registry.is_alert_enabled,
        "analytics_enabled": registry.is_analytics_enabled,
        "interval": INTERVAL
    }

class Registry:
    def __init__(self):
        self.event_id = random.randint(1000, 1500)
        self.is_analytics_enabled = False  # Current analytics state (controlled via endpoints)
        self.is_alert_enabled = False  # Start with alerts disabled
    
if __name__ == '__main__':
    registry = Registry()
    app.run(host='0.0.0.0', port=8080)
