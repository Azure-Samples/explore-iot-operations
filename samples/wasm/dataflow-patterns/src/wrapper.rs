// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// The SDK generates unsafe ABI traits without Safety documentation.
#![allow(clippy::missing_safety_doc)]

use crate::{Config, Engine};
use serde_json::Value;
use std::cell::RefCell;

thread_local! { static ENGINE: RefCell<Option<Engine>> = const { RefCell::new(None) }; }

fn initialize(configuration: ModuleConfiguration) -> bool {
    // Reinitialization failures must never leave an earlier model active.
    ENGINE.with(|state| *state.borrow_mut() = None);
    let result = (|| {
        if configuration.properties.len() != 1 || configuration.properties[0].0 != "settings" {
            return Err("exactly one configuration property named settings is required".to_owned());
        }
        Engine::new(Config::parse(&configuration.properties[0].1)?)
    })();
    match result {
        Ok(engine) => {
            ENGINE.with(|state| *state.borrow_mut() = Some(engine));
            true
        }
        Err(error) => {
            report("configurationErrors", Some(&error));
            false
        }
    }
}

fn report(counter: &str, error: Option<&str>) {
    #[cfg(target_arch = "wasm32")]
    {
        use wasm_graph_sdk::{logger, metrics};
        let _ = metrics::add_to_counter(counter, metrics::CounterValue::U64(1), None);
        if let Some(error) = error {
            logger::log(logger::Level::Error, "module-dataflow-patterns/map", error);
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    let _ = (counter, error);
}

fn observe(output: &Value) {
    match output.get("kind").and_then(Value::as_str) {
        Some("batch") => {
            report("batches", None);
            if let Some(records) = output["records"].as_array() {
                for record in records {
                    observe(record);
                }
            }
        }
        Some("diagnostic") => {
            report("diagnostics", None);
            // Fixed diagnostic codes, never user IDs, are safe metric labels.
            if let Some(code) = output["code"].as_str() {
                report(code, None);
            }
            #[cfg(target_arch = "wasm32")]
            wasm_graph_sdk::logger::log(
                wasm_graph_sdk::logger::Level::Warn,
                "module-dataflow-patterns/map",
                &output.to_string(),
            );
        }
        Some("pending") => report("pending", None),
        Some("modelApplied") => report("modelApplied", None),
        _ => report("recordsEmitted", None),
    }
}

fn data_output(output: Value) -> Value {
    if output["kind"] == "diagnostic" {
        return crate::common::pending_output();
    }
    if output["kind"] == "batch" {
        let records = output["records"]
            .as_array()
            .expect("core batch shape")
            .iter()
            .filter(|r| r["kind"] != "diagnostic")
            .cloned()
            .collect();
        return crate::common::pack(records);
    }
    output
}

#[wasm_graph_sdk::macros::map_operator(init = "initialize")]
fn map(input: DataModel) -> Result<DataModel, Error> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| Error {
            message: "processing clock precedes Unix epoch".into(),
        })?;
    let now_ms = u64::try_from(now.as_millis()).map_err(|_| Error {
        message: "processing clock overflow".into(),
    })?;
    process_at(input, now_ms)
}

fn process_at(input: DataModel, now_ms: u64) -> Result<DataModel, Error> {
    report("requests", None);
    let DataModel::Message(mut message) = input else {
        report("errors", Some("expected Message input"));
        return Err(Error {
            message: "expected Message input".into(),
        });
    };
    let result = ENGINE.with(|state| {
        let mut state = state.borrow_mut();
        state
            .as_mut()
            .ok_or_else(|| "operator is not initialized".to_owned())?
            .process(&message.payload.read(), now_ms)
    });
    let output = result.map_err(|error| {
        report("errors", Some(&error));
        Error { message: error }
    })?;
    observe(&output);
    // Operational diagnostics go to runtime logs/counters, never training topics,
    // even when cleanup and a successful match happen on the same input.
    message.payload =
        BufferOrBytes::Bytes(serde_json::to_vec(&data_output(output)).map_err(|e| Error {
            message: e.to_string(),
        })?);
    message.content_type = Some(BufferOrString::String("application/json".into()));
    // An input schema does not describe an aligned, correlated or diagnostic record.
    message.schema = None;
    Ok(DataModel::Message(message))
}

#[cfg(test)]
mod tests {
    use super::*;
    use exports::wasm_graph::processor::map::Guest;
    use serde_json::json;
    fn init(settings: &str) -> bool {
        <Module as Guest>::init(ModuleConfiguration {
            properties: vec![("settings".into(), settings.into())],
            module_schemas: vec![],
        })
    }
    fn message(v: Value) -> DataModel {
        DataModel::Message(Message {
            timestamp: Timestamp {
                timestamp: wasm_graph::processor::hybrid_logical_clock::Timespec {
                    secs: 0,
                    nanos: 0,
                },
                counter: 0,
                node_id: BufferOrString::String("test".into()),
            },
            topic: BufferOrBytes::Bytes(b"factory/input".to_vec()),
            content_type: None,
            payload: BufferOrBytes::Bytes(serde_json::to_vec(&v).unwrap()),
            properties: MessageProperties {
                user_properties: vec![],
            },
            schema: None,
        })
    }
    #[test]
    fn generated_guest_init_and_map_are_exercised() {
        assert!(init(r#"{"role":"correlate-by-id"}"#));
        let first = json!({"kind":"prediction","assetId":"a","pieceId":"p","modelVersion":8,"predictedWeight":203});
        let DataModel::Message(pending) = <Module as Guest>::process(message(first)).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            serde_json::from_slice::<Value>(&pending.payload.read()).unwrap()["kind"],
            "pending"
        );
        assert!(!module_dataflow_pattern_filter::process_payload(&pending.payload.read()).unwrap());
        let second = json!({"kind":"measurement","assetId":"a","pieceId":"p","measuredWeight":200,"targetWeight":198});
        let DataModel::Message(matched) = <Module as Guest>::process(message(second)).unwrap()
        else {
            panic!()
        };
        let out: Value = serde_json::from_slice(&matched.payload.read()).unwrap();
        assert_eq!(out["residual"], -3.);
        assert!(module_dataflow_pattern_filter::process_payload(&matched.payload.read()).unwrap());
        assert!(matched.schema.is_none());
        assert!(
            matches!(matched.content_type, Some(BufferOrString::String(ref s)) if s == "application/json")
        );
    }
    #[test]
    fn failed_reinit_clears_state_and_wrong_datamodel_is_error() {
        assert!(init(r#"{"role":"versioned-predictor"}"#));
        assert!(!init(r#"{"role":"typo"}"#));
        assert!(process_at(message(json!({"kind":"reading"})), 0).is_err());
        assert!(process_at(DataModel::BufferOrBytes(BufferOrBytes::Bytes(vec![])), 0).is_err());
    }
    #[test]
    fn map_wrapper_handles_alignment_batch_and_tick() {
        assert!(init(r#"{"role":"align-by-time"}"#));
        process_at(message(json!({"kind":"temperature","assetId":"a","sampledAt":"1970-01-01T00:00:01Z","temperature":20})),1000).unwrap();
        for second in [2, 3] {
            process_at(message(json!({"kind":"speed","assetId":"a","sampledAt":format!("1970-01-01T00:00:0{second}Z"),"speed":12})),second*1000).unwrap();
        }
        let DataModel::Message(m) = process_at(
            message(json!({"kind":"tick","assetId":"a","sampledAt":"1970-01-01T00:00:05Z"})),
            5000,
        )
        .unwrap() else {
            panic!()
        };
        assert_eq!(
            serde_json::from_slice::<Value>(&m.payload.read()).unwrap()["records"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert!(module_dataflow_pattern_filter::process_payload(&m.payload.read()).unwrap());
    }

    #[test]
    fn diagnostics_are_logged_not_mixed_into_training_batches() {
        let diagnostic = crate::common::diagnostic("expired", "a", "expired pending");
        let prediction = json!({"kind":"prediction","predictedWeight":203});
        assert_eq!(data_output(diagnostic.clone())["kind"], "pending");
        assert_eq!(
            data_output(crate::common::pack(vec![diagnostic, prediction.clone()])),
            prediction
        );
    }

    #[test]
    fn fixture_payloads_survive_map_and_filter_unchanged() {
        for text in [
            include_str!("../fixtures/align-by-time.json"),
            include_str!("../fixtures/correlate-by-id.json"),
            include_str!("../fixtures/versioned-predictor.json"),
        ] {
            let fixture: Value = serde_json::from_str(text).unwrap();
            assert!(init(&fixture["configuration"].to_string()));
            for step in fixture["steps"].as_array().unwrap() {
                let DataModel::Message(output) = process_at(
                    message(step["input"].clone()),
                    step["nowMs"].as_u64().unwrap(),
                )
                .unwrap() else {
                    panic!()
                };
                let payload = output.payload.read();
                let delivered =
                    if module_dataflow_pattern_filter::process_payload(&payload).unwrap() {
                        serde_json::from_slice::<Value>(&payload).unwrap()
                    } else {
                        Value::Null
                    };
                assert_eq!(delivered, step["expected"], "input: {}", step["input"]);
            }
        }
    }

    #[test]
    fn generated_guest_predictor_updates_do_not_trigger_predictions() {
        assert!(init(
            r#"{"role":"versioned-predictor","initialModels":[{"assetId":"a","modelVersion":7,"speedCoefficient":2,"temperatureCoefficient":0.5,"intercept":175}]}"#
        ));
        let update = json!({"kind":"model","assetId":"a","updateId":"u","expectedModelVersion":7,"modelVersion":8,"speedCoefficient":2,"temperatureCoefficient":0.5,"intercept":173});
        let DataModel::Message(ack) = <Module as Guest>::process(message(update.clone())).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            serde_json::from_slice::<Value>(&ack.payload.read()).unwrap()["kind"],
            "modelApplied"
        );
        assert!(!module_dataflow_pattern_filter::process_payload(&ack.payload.read()).unwrap());
        let DataModel::Message(duplicate) = <Module as Guest>::process(message(update)).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            serde_json::from_slice::<Value>(&duplicate.payload.read()).unwrap()["kind"],
            "pending"
        );
        assert!(
            !module_dataflow_pattern_filter::process_payload(&duplicate.payload.read()).unwrap()
        );
        let DataModel::Message(prediction) = <Module as Guest>::process(message(
            json!({"kind":"reading","assetId":"a","pieceId":"p","speed":10,"temperature":20}),
        ))
        .unwrap() else {
            panic!()
        };
        assert!(
            module_dataflow_pattern_filter::process_payload(&prediction.payload.read()).unwrap()
        );
        let prediction: Value = serde_json::from_slice(&prediction.payload.read()).unwrap();
        assert_eq!(prediction["modelVersion"], 8);
        assert_eq!(prediction["predictedWeight"], 203.);
    }
}
