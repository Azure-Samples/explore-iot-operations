# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

import json

from datetime import datetime, timedelta, timezone
from dateutil import parser
from statistics import mean, median

from cloudevents.sdk.event import v1
from dapr.clients import DaprClient
from dapr.ext.grpc import App
from numpy import percentile
from timeloop import Timeloop

DAPR_SERVER_PORT          = "6001"
PUBSUB_COMPONENT_NAME     = "iotoperations-pubsub"
STATESTORE_COMPONENT_NAME = "iotoperations-statestore"

PUBSUB_INPUT_TOPIC        = "sensor/data"
PUBSUB_OUTPUT_TOPIC       = "sensor/window_data"
STATESTORE_SENSOR_KEY     = "dapr_sample"

SENSOR_ID                 = "sensor_id"
SENSOR_TIMESTAMP          = "timestamp"
SENSOR_TEMPERATURE        = "temperature"
SENSOR_PRESSURE           = "pressure"
SENSOR_VIBRATION          = "vibration"
MSG_NUMBER                = "msg_number"

WINDOW_SIZE               = 30
PUBLISH_INTERVAL          = 10

app = App()
publish_loop = Timeloop()
tracked_sensors = set()
msg_number = 0

@app.subscribe(pubsub_name=PUBSUB_COMPONENT_NAME, topic=PUBSUB_INPUT_TOPIC, metadata={"rawPayload":"true"})
def sensordata_topic(event: v1.Event) -> None:
    global msg_number

    # extract sensor data
    data = json.loads(event.Data())
    print(f"subscribe: received sensor={data[SENSOR_ID]} number={data[MSG_NUMBER]}", flush=True)

    # extract timestamp and check for validity
    try:
        parser.parse(data[SENSOR_TIMESTAMP])
    except (ValueError, TypeError) as error:
        print(f"subscribe: discarding invalid datetime {data[SENSOR_TIMESTAMP]} for {data[SENSOR_ID]}", flush=True)
        return
    
    msg_number = data[MSG_NUMBER]

    # track the sensor for publishing window
    tracked_sensors.add(data[SENSOR_ID])

    with DaprClient() as client:
        # fetch the existing state
        state = get_state(client)

        # add the new data
        state.append(data)

        # store the state
        client.save_state(
            store_name=STATESTORE_COMPONENT_NAME, 
            key="{STATESTORE_SENSOR_KEY}/{sensor_id}", 
            value=json.dumps(state))

@publish_loop.job(interval=timedelta(seconds=PUBLISH_INTERVAL))
def slidingWindowPublish():
    time_now = datetime.now(timezone.utc)

    with DaprClient() as client:
        for sensor_id in tracked_sensors.copy():
            print(f"loop: processing {sensor_id}", flush=True)            

            temperatures = []
            pressures = []
            vibrations = []

            # fetch the current state from the state store
            state = get_state(client)

            # discard stale data
            discard_count = 0
            for data in state.copy():
                timestamp = parser.parse(data[SENSOR_TIMESTAMP])
                if time_now - timestamp > timedelta(seconds=WINDOW_SIZE):
                    state.remove(data)
                    discard_count += 1

            # process current data
            for data in state:
                temperatures.append(data[SENSOR_TEMPERATURE])
                pressures.append(data[SENSOR_PRESSURE])
                vibrations.append(data[SENSOR_VIBRATION])
            
            print(f"loop: processed={len(state)} discarded={discard_count}", flush=True)

            # store the new state in the state store
            client.save_state(
                store_name=STATESTORE_COMPONENT_NAME, 
                key="{STATESTORE_SENSOR_KEY}/{sensor_id}", 
                value=json.dumps(state))

            # create payload
            publish_state = { 
                "timestamp": time_now.isoformat(),
                "window_size": WINDOW_SIZE
            }
            append_data(publish_state, "temperature", temperatures)
            append_data(publish_state, "pressure", pressures)
            append_data(publish_state, "vibration", vibrations)

            # publish window data
            client.publish_event(
                pubsub_name=PUBSUB_COMPONENT_NAME, 
                topic_name=PUBSUB_OUTPUT_TOPIC, 
                data=json.dumps(publish_state, indent=4), 
                data_content_type='application/json',
                publish_metadata={"rawPayload":"true"})

            # stop tracking sensor if state is empty
            if not state:
                print(f"loop: stopped tracking {sensor_id}", flush=True)
                tracked_sensors.remove(sensor_id)

def get_state(client):
    response = client.get_state(
        store_name=STATESTORE_COMPONENT_NAME, 
        key="{STATESTORE_SENSOR_KEY}/{sensor_id}")
    
    try:
        state = json.loads(response.data)
        if type(state) != list:
            print("get_state: state is not an array, initializing", flush=True)
            state = []
    except ValueError:
        state = []
        print("get_state: state is invalid or empty, initializing", flush=True)

    return state

def append_data(state, sensor_name, data):
    if data:
        state[sensor_name] = {
            "min"    : min(data),
            "max"    : max(data),
            "mean"   : mean(data),
            "median" : median(data),
            "75per"  : percentile(data, 75),
            "count"  : len(data),
        }
        print(f"loop: sensor={sensor_name}"
            f" min={state[sensor_name]['min']}"
            f" max={state[sensor_name]['max']}"
            f" mean={state[sensor_name]['mean']}"
            f" median={state[sensor_name]['median']}"
            f" 75%={state[sensor_name]['75per']}", flush=True)

# Start the window publish loop
publish_loop.start(block=False)

# Start the Dapr server
app.run(DAPR_SERVER_PORT)
