// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Generated by `wit_bindgen::generate` expansion.
#![allow(clippy::missing_safety_doc)]

// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// Generated by `wit_bindgen::generate` expansion.
#![allow(clippy::missing_safety_doc)]

mod map_temperature {
    use crate::{Measurement, MeasurementTemperatureUnit};

    use tinykube_wasm_sdk::logger::{self, Level};
    use tinykube_wasm_sdk::macros::map_operator;
    use tinykube_wasm_sdk::metrics::{self, CounterValue, Label};

    fn fahrenheit_to_celsius_init(configuration: ModuleConfiguration) -> bool {
        logger::log(
            Level::Info,
            "module-temperature/map",
            &format!("Initialization function invoked"),
        );

        for (key, value) in configuration.properties {
            logger::log(
                Level::Info,
                "module-temperature/map",
                &format!("Initialization received the property (key='{key}', value='{value}')."),
            );
        }

        for module_schema in configuration.module_schemas {
            logger::log(
                Level::Info,
                "module-temperature/map",
                &format!("Initialization received the schema '{module_schema:?}'."),
            );
        }

        true
    }

    fn log_schema_and_content_type(message: &Message) {
        if let Some(schema) = &message.schema {
            match schema {
                MessageSchema::RegistryReference(reference) => {
                    match reference {
                        BufferOrString::Buffer(reference) => {
                            let reference = reference.read();
                            logger::log(
                                Level::Info,
                                "module-temperature/map",
                                &format!("Registry reference schema (buffer)='{:?}'",
                                        reference),
                            );
                        }
                        BufferOrString::String(_reference) => {
                            panic!("Test should not specify non-buffers");
                        }
                    }
                }
                MessageSchema::Inline(inline_schema) => {
                    match &inline_schema.name {
                        BufferOrString::Buffer(name) => {
                            let name = name.read();
                            logger::log(
                                Level::Info,
                                "module-temperature/map",
                                &format!("Inline schema (buffer)='{:?}'",
                                        name),
                            );
                        }
                        BufferOrString::String(_reference) => {
                            panic!("Test should not specify non-buffers");
                        }
                    }

                    match &inline_schema.content {
                        BufferOrString::Buffer(content) => {
                            let content = content.read();
                            logger::log(
                                Level::Info,
                                "module-temperature/map",
                                &format!("Inline content (buffer)='{:?}'",
                                        content),
                            );
                        }
                        BufferOrString::String(_content) => {
                            panic!("Test should not specify non-buffers");
                        }
                    }
                }
            }
        } else {
            logger::log(
                Level::Info,
                "module-temperature/map",
                &format!("Schema not specified"),
            );
        }

        if let Some(content_type) = &message.content_type {
            match content_type {
                BufferOrString::Buffer(content_type) => {
                    let content_type = content_type.read();
                    logger::log(
                        Level::Info,
                        "module-temperature/map",
                        &format!("Content Type (buffer)='{:?}'",
                                content_type),
                    );
                }
                BufferOrString::String(_content_type) => {
                    panic!("Test should not specify non-buffers");
                }
            }
        } else {
            logger::log(
                Level::Info,
                "module-temperature/map",
                &format!("Serialization format not specified"),
            );
        }
    }

    #[map_operator(init = "fahrenheit_to_celsius_init")]
    fn fahrenheit_to_celsius(input: DataModel) -> DataModel {
        let labels = vec![Label {
            key: "module".to_owned(),
            value: "module-temperature/map".to_owned(),
        }];
        let _ = metrics::add_to_counter("requests", CounterValue::U64(1), Some(&labels));

        // Default result is unmodified input
        let DataModel::Message(mut result) = input else {
            panic!("Unexpected input type");
        };

        log_schema_and_content_type(&result);

        // Extract payload from message to process
        let payload = &result.payload.read();

        let measurement: Measurement = serde_json::from_slice(payload).unwrap();

        logger::log(
            Level::Info,
            "module-temperature/map",
            &format!("incoming measurement {measurement:?}"),
        );

        if let Measurement::Temperature(mut measurement) = measurement {
            if measurement.unit == MeasurementTemperatureUnit::Fahrenheit {
                let labels = vec![
                    Label {
                        key: "module".to_owned(),
                        value: "module-temperature/map".to_owned(),
                    },
                    Label {
                        key: "unit".to_owned(),
                        value: "Fahrenheit".to_string(),
                    },
                ];
                let _ = metrics::add_to_counter("requests", CounterValue::U64(1), Some(&labels));

                measurement.value = Some((measurement.value.unwrap() - 32.) * 5. / 9.);
                measurement.unit = MeasurementTemperatureUnit::Celsius;
                let payload = serde_json::to_vec(&Measurement::Temperature(measurement)).unwrap();
                result.payload = BufferOrBytes::Bytes(payload);
            } else {
                let labels = vec![
                    Label {
                        key: "module".to_owned(),
                        value: "module-temperature/map".to_owned(),
                    },
                    Label {
                        key: "unit".to_owned(),
                        value: "Celsius".to_string(),
                    },
                ];
                let _ = metrics::add_to_counter("requests", CounterValue::U64(1), Some(&labels));
            }
        }

        //Iterate over the properties and modify the property with key "test_property_key" if it exists
        // Aslo logs all properties keys
        for (key, value) in result.properties.user_properties.iter_mut() {
            let property_key: String = match key {
                BufferOrString::Buffer(buffer) => String::from_utf8(buffer.read()).unwrap(),
                BufferOrString::String(string) => string.to_owned(),
            };

            if property_key == "test_property_key" {
                *value = BufferOrString::String("new_value".to_owned());
            }

            logger::log(
                Level::Info,
                "module-temperature/map",
                &format!("incoming property {property_key:?}"),
            );
        }

        DataModel::Message(result)
    }
}

mod branch_temperature {
    use crate::Measurement;

    use tinykube_wasm_sdk::logger::{self, Level};
    use tinykube_wasm_sdk::macros::branch_operator;
    use tinykube_wasm_sdk::metrics::{self, CounterValue, Label};

    fn check_temperature_init(configuration: ModuleConfiguration) -> bool {
        logger::log(
            Level::Info,
            "module-temperature/branch",
            &format!("Initialization function invoked"),
        );

        for (key, value) in configuration.properties {
            logger::log(
                Level::Info,
                "module-temperature/branch",
                &format!("Initialization received the property (key='{key}', value='{value}')."),
            );
        }

        for module_schema in configuration.module_schemas {
            logger::log(
                Level::Info,
                "module-temperature/branch",
                &format!("Schema input = '{module_schema:?}'."),
            );
        }

        true
    }

    #[branch_operator(init = "check_temperature_init")]
    fn check_temperature(_timestamp: HybridLogicalClock, input: DataModel) -> bool {
        let labels = vec![Label {
            key: "module".to_owned(),
            value: "module-temperature/branch".to_owned(),
        }];

        let _ = metrics::add_to_counter("requests", CounterValue::U64(1), Some(&labels));

        let DataModel::Message(message) = input else {
            panic!("Unexpected input type");
        };

        // Extract payload from message to process
        let payload = &message.payload.read();

        let measurement: Measurement = serde_json::from_slice(payload).unwrap();

        match measurement {
            Measurement::Temperature(_measurement) => true,
            _ => false,
        }
    }
}

mod filter_temperature {
    use core::panic;
    use std::sync::OnceLock;

    use crate::{Measurement, MeasurementTemperature, MeasurementTemperatureUnit};

    use tinykube_wasm_sdk::logger::{self, Level};
    use tinykube_wasm_sdk::macros::filter_operator;
    use tinykube_wasm_sdk::metrics::{self, CounterValue, Label};

    static LOWER_BOUND: OnceLock<f64> = OnceLock::new();
    static UPPER_BOUND: OnceLock<f64> = OnceLock::new();

    // Note!: The initialization parameters LOWER_BOUND and UPPER_BOUND must be set via
    // configuration properties. If these values are not configured, the function
    // filter_temperature will panic when attempting to access them.
    //
    // Users can define these parameters either by using default values or by specifying
    // them during application setup.
    fn filter_temperature_init(configuration: ModuleConfiguration) -> bool {
        logger::log(
            Level::Info,
            "module-temperature/filter",
            &format!("Initialization function invoked"),
        );

        if let Some(value_string) = configuration
            .properties
            .iter()
            .find(|(key, _value)| key == "temperature_lower_bound") // or whatever it is
            .map(|(_key, value)| value.clone())
        {
            match value_string.parse::<f64>() {
                Ok(value) => {
                    LOWER_BOUND.set(value).unwrap();
                    logger::log(
                        Level::Info,
                        "module-temperature/filter",
                        &format!("Lower bound set to {value}"),
                    );
                }
                Err(_) => {
                    logger::log(
                        Level::Error,
                        "module-temperature/filter",
                        &format!("Failed to parse lower bound value: {value_string}"),
                    );
                }
            }
        }

        if let Some(value_string) = configuration
            .properties
            .iter()
            .find(|(key, _value)| key == "temperature_upper_bound") // or whatever it is
            .map(|(_key, value)| value.clone())
        {
            match value_string.parse::<f64>() {
                Ok(value) => {
                    UPPER_BOUND.set(value).unwrap();
                    logger::log(
                        Level::Info,
                        "module-temperature/filter",
                        &format!("Upper bound set to {value}"),
                    );
                }
                Err(_) => {
                    logger::log(
                        Level::Error,
                        "module-temperature/filter",
                        &format!("Failed to parse upper bound value: {value_string}"),
                    );
                }
            }
        }

        true
    }

    #[filter_operator(init = "filter_temperature_init")]
    fn filter_temperature(input: DataModel) -> bool {
        let labels = vec![Label {
            key: "module".to_owned(),
            value: "module-temperature/filter".to_owned(),
        }];
        let _ = metrics::add_to_counter("requests", CounterValue::U64(1), Some(&labels));

        // Extract payload from input to process
        let payload = match input {
            DataModel::Message(Message {
                payload: BufferOrBytes::Buffer(buffer),
                ..
            }) => buffer.read(),
            _ => panic!("Unexpected input type"),
        };

        let measurement: Measurement = serde_json::from_slice(&payload).unwrap();

        logger::log(
            Level::Info,
            "module-temperature/filter",
            &format!("incoming measurement {measurement:?}"),
        );

        let lower_bound = LOWER_BOUND
            .get()
            .expect("Lower bound not initialized");
        let upper_bound = UPPER_BOUND
            .get()
            .expect("Upper bound not initialized");

        // Malfunctioning probe sometimes reports higher temperature than melting point of tungsten.
        // Ignore these values.
        matches!(
            measurement,
            Measurement::Temperature(MeasurementTemperature {
                count: _,
                value,
                max: _,
                min: _,
                average: _,
                last: _,
                unit: MeasurementTemperatureUnit::Celsius,
                overtemp: _,
            }) if value.unwrap() < *upper_bound && value.unwrap() > *lower_bound,
        )
    }
}

mod accumulate_temperature {
    use crate::{Measurement, MeasurementTemperatureUnit};

    use tinykube_wasm_sdk::logger::{self, Level};
    use tinykube_wasm_sdk::macros::accumulate_operator;
    use tinykube_wasm_sdk::metrics::{self, CounterValue, Label};

    fn accumulate_temperature_values_init(configuration: ModuleConfiguration) -> bool {
        logger::log(
            Level::Info,
            "module-temperature/accumulate",
            &format!("Initialization function invoked"),
        );

        for (key, value) in configuration.properties {
            logger::log(
                Level::Info,
                "module-temperature/accumulate",
                &format!("Initialization received the property (key='{key}', value='{value}')."),
            );
        }

        true
    }

    #[accumulate_operator(init = "accumulate_temperature_values_init")]
    fn accumulate_temperature_values(staged: DataModel, inputs: Vec<DataModel>) -> DataModel {
        let labels = vec![Label {
            key: "module".to_owned(),
            value: "module-temperature/accumulate".to_owned(),
        }];
        let _ = metrics::add_to_counter("requests", CounterValue::U64(1), Some(&labels));

        let DataModel::Message(mut result) = staged else {
            panic!("Unexpected input type");
        };

        // Extract payload from message to process
        let staged_payload = match &result.payload {
            BufferOrBytes::Buffer(buffer) => buffer.read(),
            BufferOrBytes::Bytes(bytes) => bytes.clone(),
        };

        let (mut count, mut avg, mut max, mut min, mut last) = if staged_payload.is_empty() {
            (0, 0.0, f64::MIN, f64::MAX, 0.0)
        } else {
            match serde_json::from_slice(&staged_payload).unwrap() {
                Measurement::Temperature(measurement) => {
                    // average * count = sum; avg works as the sum before divided by count.
                    let count = measurement.count;
                    let sum = measurement.average * count as f64;
                    (
                        count,
                        sum,
                        measurement.max,
                        measurement.min,
                        measurement.last,
                    )
                }
                _ => (0, 0.0, f64::MIN, f64::MAX, 0.0),
            }
        };

        let mut last_secs = 0;
        let mut last_nanos = 0;
        let mut unit = MeasurementTemperatureUnit::Celsius;
        let mut result_topic = BufferOrBytes::Bytes(Vec::new());

        for input in inputs {
            let (ts, topic, payload) = match input {
                DataModel::Message(temp) => {
                    // Extract payload from message to process
                    (
                        temp.timestamp.timestamp,
                        temp.topic,
                        match &temp.payload {
                            BufferOrBytes::Buffer(buffer) => buffer.read(),
                            BufferOrBytes::Bytes(bytes) => bytes.clone(),
                        },
                    )
                }
                _ => panic!("Unexpected input type"),
            };

            let measurement: Measurement = serde_json::from_slice(&payload).unwrap();
            match measurement {
                Measurement::Temperature(measurement) => {
                    let value = measurement.value.unwrap();
                    // Add each temperature into average
                    avg += value;
                    count += 1;

                    // Compare and return max and min values
                    if value > max {
                        max = value;
                    }
                    if value < min {
                        min = value;
                    }

                    // Compare the obtain the latest value
                    if ts.secs >= last_secs || (ts.secs == last_secs && ts.nanos >= last_nanos) {
                        last = value;
                        last_secs = ts.secs;
                        last_nanos = ts.nanos;
                    }

                    // Set the unit
                    unit = measurement.unit;

                    // Set the topic
                    result_topic = topic;
                }
                _ => panic!("Unexpected measurement type."),
            }
        }

        // Compute average temperature
        avg /= count as f64;

        // Deserialize the unit
        let unit_str = match unit {
            MeasurementTemperatureUnit::Celsius => "C",
            MeasurementTemperatureUnit::Fahrenheit => "F",
        };

        // Create the payload
        let payload_str = format!(
            r#"{{"temperature":{{"count":{count},"max":{max},"min":{min},"average":{avg},"last":{last},"unit":"{unit_str}"}}}}"#,
        );

        logger::log(Level::Info, "module-temperature/accumulate", &payload_str);

        let payload = payload_str.as_bytes().to_vec();
        result.payload = BufferOrBytes::Bytes(payload);
        result.timestamp.timestamp.secs = last_secs;
        result.timestamp.timestamp.nanos = last_nanos;
        result.topic = result_topic;
        DataModel::Message(result)
    }
}


#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum Measurement {
    #[serde(rename = "temperature")]
    Temperature(MeasurementTemperature),

    #[serde(rename = "humidity")]
    Humidity(MeasurementHumidity),

    #[serde(rename = "object")]
    Object(MeasurementObject),

    #[serde(rename = "sensor_data")]
    SensorData(MeasurementSensorData),
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct MeasurementTemperature {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    #[serde(default)]
    pub count: u64,
    #[serde(default)]
    pub max: f64,
    #[serde(default)]
    pub min: f64,
    #[serde(default)]
    pub average: f64,
    #[serde(default)]
    pub last: f64,
    pub unit: MeasurementTemperatureUnit,
    #[serde(default)]
    pub overtemp: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub enum MeasurementTemperatureUnit {
    #[serde(rename = "C")]
    Celsius,

    #[serde(rename = "F")]
    Fahrenheit,
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct MeasurementHumidity {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    #[serde(default)]
    pub count: u64,
    #[serde(default)]
    pub max: f64,
    #[serde(default)]
    pub min: f64,
    #[serde(default)]
    pub average: f64,
    #[serde(default)]
    pub last: f64,
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct MeasurementObject {
    pub result: String,
}

#[derive(Debug, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct MeasurementSensorData {
    #[serde(default)]
    pub temperature: Vec<MeasurementTemperature>,

    #[serde(default)]
    pub humidity: Vec<MeasurementHumidity>,

    #[serde(default)]
    pub object: Vec<MeasurementObject>,
}

impl Default for MeasurementSensorData {
    fn default() -> Self {
        Self::new()
    }
}

impl MeasurementSensorData {
    pub fn new() -> Self {
        Self {
            temperature: Vec::new(),
            humidity: Vec::new(),
            object: Vec::new(),
        }
    }

    pub fn temperature(&mut self) -> &mut [MeasurementTemperature] {
        &mut self.temperature
    }

    pub fn humidity(&mut self) -> &mut [MeasurementHumidity] {
        &mut self.humidity
    }

    pub fn object(&mut self) -> &mut [MeasurementObject] {
        &mut self.object
    }
}
