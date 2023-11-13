# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

import json
from datetime import datetime, timedelta, timezone
from dateutil import parser
from statistics import mean, median

from cloudevents.sdk.event import v1
from dapr.clients import DaprClient
from dapr.ext.grpc import App
from timeloop import Timeloop

# debugger
#import ptvsd
#ptvsd.enable_attach()

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

TIMESTAMP_FORMAT          = "%Y-%m-%dT%H:%M:%S.%3NZ"
WINDOW_SIZE               = 60
PUBLISH_INTERVAL          = 10

app = App()
publish_loop = Timeloop()
tracked_sensors = {}

@app.subscribe(pubsub_name=PUBSUB_COMPONENT_NAME, topic=PUBSUB_INPUT_TOPIC)
def sensordata_topic(event: v1.Event) -> None:

    # extract the sensor_id to use as the key to DSS
    sensor_id = event.Extensions()[SENSOR_ID]
    print(f"subscribe: received data from sensor: {sensor_id}")

    # extract sensor information
    sensor = {}
    sensor[SENSOR_TIMESTAMP] = datetime.now(timezone.utc).isoformat() #event.Extensions()[SENSOR_TIMESTAMP]
    sensor[SENSOR_TEMPERATURE] = event.Extensions()[SENSOR_TEMPERATURE]
    sensor[SENSOR_PRESSURE] = event.Extensions()[SENSOR_PRESSURE]
    sensor[SENSOR_VIBRATION] = event.Extensions()[SENSOR_VIBRATION]

    # extract timestamp and check for validity
    try:
        parser.parse(sensor[SENSOR_TIMESTAMP])
    except (ValueError, TypeError) as error:
        print(f"subscribe: discarding invalid datetime {sensor[SENSOR_TIMESTAMP]} for {sensor_id}")
        return

    # track the sensor for publishing window
    tracked_sensors[sensor_id] = True

    with DaprClient() as client:
        # fetch the existing state
        response = client.get_state(store_name=STATESTORE_COMPONENT_NAME, key="{STATESTORE_SENSOR_KEY}/{sensor_id}", state_metadata={"metakey": "metavalue"})

        try:
            state = json.loads(response.data)
            if type(state) != list:
                print("subscribe: state is not an array, initialising")
                state = []
        except ValueError:
            state = []
            print("subscribe: state is invalid or empty, initialising")

        # add the new value
        state.append(sensor)

        # store the state
        client.save_state(store_name=STATESTORE_COMPONENT_NAME, key="{STATESTORE_SENSOR_KEY}/{sensor_id}", value=json.dumps(state))
        print(f"subscribe: stored state {state}")

@publish_loop.job(interval=timedelta(seconds=PUBLISH_INTERVAL))
def slidingWindowPublish():
    print("loop: publishing window")

    time_now = datetime.now(timezone.utc)

    with DaprClient() as client:
        for sensor_id in tracked_sensors:
            if not tracked_sensors[sensor_id]:
                continue

            print(f"loop: processing sensor {sensor_id}")            

            temperatures = []
            pressures = []
            vibrations = []

            # fetch the existing state
            response = client.get_state(store_name=STATESTORE_COMPONENT_NAME, key="{STATESTORE_SENSOR_KEY}/{sensor_id}", state_metadata={"metakey": "metavalue"})
            try:
                state = json.loads(response.data)
                if type(state) != list:
                    state = []                
            except ValueError:
                state = []

            new_state = []

            # process current data, expire old data
            for sensor in state:
                timestamp = parser.parse(sensor[SENSOR_TIMESTAMP])
                if timestamp + timedelta(seconds=WINDOW_SIZE) > time_now:
                    print(f"loop: processing {timestamp}, {sensor}")

                    # stash the values
                    temperatures.append(sensor[SENSOR_TEMPERATURE])
                    pressures.append(sensor[SENSOR_PRESSURE])
                    vibrations.append(sensor[SENSOR_VIBRATION])

                    # save the data for the next windows process
                    new_state.append(sensor)
                else:
                    print(f"loop: discarded {sensor}")

            # store the state
            client.save_state(store_name=STATESTORE_COMPONENT_NAME, key="{STATESTORE_SENSOR_KEY}/{sensor_id}", value=json.dumps(new_state))
            print(f"loop: stored state {new_state}")

            # publish window
            publish_state = {}
            if temperatures:
                publish_state["temperature"] = {
                    "min" : min(temperatures),
                    "max" : max(temperatures),
                    "mean": mean(temperatures),
                }
            if pressures:
                publish_state["pressure"] = {
                    "min" : min(pressures),
                    "max" : max(pressures),
                    "mean": mean(pressures),
                }
            if vibrations:
                publish_state["vibration"] = {
                    "min" : min(vibrations),
                    "max" : max(vibrations),
                    "mean": mean(vibrations),
                },                                

            client.publish_event(pubsub_name=PUBSUB_COMPONENT_NAME, topic_name=PUBSUB_OUTPUT_TOPIC, data=json.dumps(publish_state))

            # stop tracking if array is empty
            if not new_state:
                print(f"loop: stopped tracking {sensor_id}")
                tracked_sensors[sensor_id] = False

publish_loop.start(block=False)
app.run(DAPR_SERVER_PORT)
