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
PUBSUB_COMPONENT_NAME     = "aio-mq-pubsub"
STATESTORE_COMPONENT_NAME = "aio-mq-statestore"

PUBSUB_INPUT_TOPIC        = "sensor/data"
PUBSUB_OUTPUT_TOPIC       = "sensor/window_data"
STATESTORE_SENSOR_KEY     = "dapr_sample"

SENSOR_ID                 = "sensor_id"
SENSOR_TIMESTAMP          = "timestamp"
SENSOR_TEMPERATURE        = "temperature"
SENSOR_PRESSURE           = "pressure"
SENSOR_VIBRATION          = "vibration"

WINDOW_SIZE               = 30
PUBLISH_INTERVAL          = 10

app = App()
publish_loop = Timeloop()
tracked_sensors = set()

@app.subscribe(pubsub_name=PUBSUB_COMPONENT_NAME, topic=PUBSUB_INPUT_TOPIC, metadata={"rawPayload":"true"})
def sensordata_topic(event: v1.Event) -> None:
    # extract sensor data
    data = json.loads(event.Data())
    print(f"subscribe: received {data[SENSOR_ID]}")

    # extract timestamp and check for validity
    try:
        parser.parse(data[SENSOR_TIMESTAMP])
    except (ValueError, TypeError) as error:
        print(f"subscribe: discarding invalid datetime {data[SENSOR_TIMESTAMP]} for {data[SENSOR_ID]}")
        return

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
            print(f"loop: processing {sensor_id}")            

            temperatures = []
            pressures = []
            vibrations = []

            # fetch the existing state
            state = get_state(client)

            # remove stale data
            for data in state.copy():
                timestamp = parser.parse(data[SENSOR_TIMESTAMP])
                if time_now - timestamp > timedelta(seconds=WINDOW_SIZE):
                    print(f"loop: discarded age={(time_now - timestamp).total_seconds()}, data={data}")
                    state.remove(data)

            # process current data
            for data in state:
                print(f"loop: processing {data}")

                # stash the values
                temperatures.append(data[SENSOR_TEMPERATURE])
                pressures.append(data[SENSOR_PRESSURE])
                vibrations.append(data[SENSOR_VIBRATION])

            # store the new state
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
                data=json.dumps(publish_state), 
                publish_metadata={"rawPayload":"true"})

            # stop tracking sensor if state is empty
            if not state:
                print(f"loop: stopped tracking {sensor_id}")
                tracked_sensors.remove(sensor_id)

def get_state(client):
    response = client.get_state(
        store_name=STATESTORE_COMPONENT_NAME, 
        key="{STATESTORE_SENSOR_KEY}/{sensor_id}", 
        state_metadata={"metakey": "metavalue"})
    
    try:
        state = json.loads(response.data)
        if type(state) != list:
            print("get_state: state is not an array, initialising")
            state = []
    except ValueError:
        state = []
        print("get_state: state is invalid or empty, initialising")

    return state

def append_data(state, sensor_name, data):
    if data:
        state[sensor_name] = {
            "min"    : min(data),
            "max"    : max(data),
            "mean"   : mean(data),
            "median" : median(data),
            "75_per" : percentile(data, 75),
            "count"  : len(data),
        }

# Start the window publish loop
publish_loop.start(block=False)

# Start the Dapr server
app.run(DAPR_SERVER_PORT)
