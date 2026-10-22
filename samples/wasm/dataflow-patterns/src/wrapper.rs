// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// The SDK generates unsafe ABI traits without Safety documentation.
#![allow(clippy::missing_safety_doc)]

use crate::{Config, Engine};
use serde_json::Value;
use std::cell::RefCell;
use std::collections::BTreeMap;

struct Operator {
    engine: Engine,
    input_topics: Option<BTreeMap<String, String>>,
}

thread_local! { static ENGINE: RefCell<Option<Operator>> = const { RefCell::new(None) }; }

fn initialize(configuration: ModuleConfiguration) -> bool {
    // Reinitialization failures must never leave an earlier model active.
    ENGINE.with(|state| *state.borrow_mut() = None);
    let result = (|| {
        if configuration.properties.len() != 1 || configuration.properties[0].0 != "settings" {
            return Err("exactly one configuration property named settings is required".to_owned());
        }
        let config = Config::parse(&configuration.properties[0].1)?;
        if !config.role.input_kinds().is_empty() && config.input_topics.is_none() {
            return Err("inputTopics is required for this role at the MQTT wrapper".to_owned());
        }
        let input_topics = config.input_topics.clone();
        Ok(Operator {
            engine: Engine::new(config)?,
            input_topics,
        })
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
        let operator = state
            .as_mut()
            .ok_or_else(|| "operator is not initialized".to_owned())?;
        let payload = message.payload.read();
        if let Some(topics) = &operator.input_topics {
            if payload.len() > 65_536 {
                return Err("input JSON exceeds 65536 bytes".to_owned());
            }
            let value: Value =
                serde_json::from_slice(&payload).map_err(|e| format!("invalid JSON: {e}"))?;
            let topic = message.topic.read();
            let authorized = value
                .get("kind")
                .and_then(Value::as_str)
                .and_then(|kind| topics.get(kind))
                .is_some_and(|expected| expected.as_bytes() == topic.as_slice());
            if !authorized {
                return Err("input topic is not authorized for payload kind".to_owned());
            }
        }
        operator.engine.process(&payload, now_ms)
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
        message_on("factory/smoothing-readings", v)
    }
    fn message_on(topic: &str, v: Value) -> DataModel {
        DataModel::Message(Message {
            timestamp: Timestamp {
                timestamp: wasm_graph::processor::hybrid_logical_clock::Timespec {
                    secs: 0,
                    nanos: 0,
                },
                counter: 0,
                node_id: BufferOrString::String("test".into()),
            },
            topic: BufferOrBytes::Bytes(topic.as_bytes().to_vec()),
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
            include_str!("../fixtures/report-by-exception.json"),
            include_str!("../fixtures/stable-alarm.json"),
            include_str!("../fixtures/offline-detection.json"),
            include_str!("../fixtures/running-total.json"),
            include_str!("../fixtures/smooth-readings.json"),
        ] {
            let mut fixture: Value = serde_json::from_str(text).unwrap();
            let role = fixture["configuration"]["role"].as_str().unwrap();
            let topics = bindings(role);
            if !topics.is_empty() {
                fixture["configuration"]["inputTopics"] = json!(topics);
            }
            assert!(init(&fixture["configuration"].to_string()));
            for step in fixture["steps"].as_array().unwrap() {
                if !topics.is_empty()
                    && !topics.contains_key(step["input"]["kind"].as_str().unwrap())
                {
                    // Pure-core fixtures can exercise no-op kinds that the broker
                    // boundary deliberately does not authorize (e.g. smoothing ticks).
                    assert!(process_at(
                        message(step["input"].clone()),
                        step["nowMs"].as_u64().unwrap()
                    )
                    .is_err());
                    continue;
                }
                let topic = topics
                    .get(step["input"]["kind"].as_str().unwrap())
                    .map(String::as_str)
                    .unwrap_or("factory/input");
                let DataModel::Message(output) = process_at(
                    message_on(topic, step["input"].clone()),
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
    fn generated_guest_smoothing_preserves_metadata_and_suppresses_retries() {
        assert!(init(
            r#"{"role":"smooth-readings","alpha":0.25,"inputTopics":{"reading":"factory/smoothing-readings"}}"#
        ));
        let first = json!({
            "kind":"reading","assetId":"sensor-1","messageId":"r0",
            "sequence":0,"value":10,"units":"C","trace":{"source":"synthetic"}
        });
        let DataModel::Message(mut input) = message(first.clone()) else {
            panic!()
        };
        input.properties.user_properties.push((
            BufferOrString::String("trace".into()),
            BufferOrString::String("sdk-test".into()),
        ));
        let DataModel::Message(output) =
            <Module as Guest>::process(DataModel::Message(input)).unwrap()
        else {
            panic!()
        };
        let payload = output.payload.read();
        let actual: Value = serde_json::from_slice(&payload).unwrap();
        let mut expected = first.clone();
        expected["kind"] = json!("smoothed");
        expected["smoothedValue"] = json!(10.0);
        expected["emittedAtMs"] = actual["emittedAtMs"].clone();
        assert!(actual["emittedAtMs"].as_u64().is_some());
        assert_eq!(actual, expected);
        assert!(module_dataflow_pattern_filter::process_payload(&payload).unwrap());
        assert_eq!(output.topic.read(), b"factory/smoothing-readings");
        assert_eq!(output.properties.user_properties.len(), 1);
        assert!(matches!(
            &output.properties.user_properties[0],
            (BufferOrString::String(key), BufferOrString::String(value))
                if key == "trace" && value == "sdk-test"
        ));
        assert!(output.schema.is_none());
        assert!(
            matches!(output.content_type, Some(BufferOrString::String(ref s)) if s == "application/json")
        );

        let mut changed = first.clone();
        changed["value"] = json!(999);
        for rejected in [first, changed] {
            let DataModel::Message(output) = <Module as Guest>::process(message(rejected)).unwrap()
            else {
                panic!()
            };
            assert_eq!(
                serde_json::from_slice::<Value>(&output.payload.read()).unwrap(),
                json!({"kind":"pending"})
            );
            assert!(
                !module_dataflow_pattern_filter::process_payload(&output.payload.read()).unwrap()
            );
        }
        let DataModel::Message(output) = <Module as Guest>::process(message(json!({
            "kind":"reading","assetId":"sensor-1","messageId":"r1","sequence":1,"value":11
        })))
        .unwrap() else {
            panic!()
        };
        let actual: Value = serde_json::from_slice(&output.payload.read()).unwrap();
        assert_eq!(actual["smoothedValue"], 10.25);
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

    fn bindings(role: &str) -> BTreeMap<String, String> {
        let pairs: &[(&str, &str)] = match role {
            "report-by-exception" => &[("reading", "report-readings"), ("tick", "report-ticks")],
            "stable-alarm" => &[("reading", "alarm-readings"), ("tick", "alarm-ticks")],
            "offline-detection" => &[
                ("reading", "availability-readings"),
                ("tick", "availability-ticks"),
                ("register", "availability-registers"),
            ],
            "running-total" => &[("reading", "total-readings"), ("reset", "total-resets")],
            "smooth-readings" => &[("reading", "smoothing-readings")],
            _ => &[],
        };
        pairs
            .iter()
            .map(|(kind, suffix)| (kind.to_string(), format!("factory/{suffix}")))
            .collect()
    }

    fn output_on(topic: &str, input: Value, now: u64) -> Value {
        let DataModel::Message(output) = process_at(message_on(topic, input), now).unwrap() else {
            panic!()
        };
        serde_json::from_slice(&output.payload.read()).unwrap()
    }

    #[test]
    fn all_new_roles_require_complete_bindings_at_sdk_initialization() {
        for role in [
            "report-by-exception",
            "stable-alarm",
            "offline-detection",
            "running-total",
            "smooth-readings",
        ] {
            assert!(!init(&json!({"role":role}).to_string()));
            assert!(init(
                &json!({"role":role,"inputTopics":bindings(role)}).to_string()
            ));
            assert!(!init(&json!({"role":role,"inputTopics":{}}).to_string()));
            assert!(process_at(message(json!({"kind":"reading"})), 0).is_err());
        }
    }

    #[test]
    fn invalid_topic_maps_are_rejected_without_relaxing_pure_engine_config() {
        for topics in [
            Value::Null,
            json!([]),
            json!("factory/input"),
            json!({"reading":1}),
            json!({"reading":""}),
            json!({"reading":"factory/+"}),
            json!({"reading":"factory/#"}),
            json!({"reading":"factory/\u{0}"}),
            json!({"reading":"factory/\n"}),
            json!({"reading":"factory/input","extra":"factory/extra"}),
        ] {
            assert!(Config::parse(
                &json!({"role":"smooth-readings","inputTopics":topics}).to_string()
            )
            .is_err());
        }
        assert!(!init(
            r#"{"role":"running-total","inputTopics":{"reading":"same","reset":"same"}}"#
        ));
        assert!(!init(
            r#"{"role":"smooth-readings","inputTopics":{"reading":"a","reading":"b"}}"#
        ));
        assert!(!init(
            r#"{"role":"versioned-predictor","inputTopics":{"reading":"a"}}"#
        ));
        for role in [
            "report-by-exception",
            "stable-alarm",
            "offline-detection",
            "running-total",
            "smooth-readings",
        ] {
            // Core replay remains transport-independent; only the wrapper requires bindings.
            assert!(Engine::new(Config::parse(&json!({"role":role}).to_string()).unwrap()).is_ok());
        }
    }

    #[test]
    fn forged_reset_on_readings_is_sdk_error_without_mutation() {
        assert!(init(
            &json!({
                "role":"running-total","inputTopics":bindings("running-total"),
                "initialStates":[{"assetId":"sensor-1","total":12,"stateVersion":4,
                                  "epoch":0,"lastSequence":0}]
            })
            .to_string()
        ));
        let reset = json!({"kind":"reset","assetId":"sensor-1","resetId":"r1",
                           "sequence":1,"expectedStateVersion":4});
        assert!(
            <Module as Guest>::process(message_on("factory/total-readings", reset.clone()))
                .is_err()
        );
        let actual = output_on("factory/total-resets", reset, 1);
        assert_eq!(actual["kind"], "totalReset");
        assert_eq!(actual["stateVersion"], 5);
        assert_eq!(actual["epoch"], 1);
        assert_eq!(actual["total"], 0.0);
    }

    #[test]
    fn forged_ticks_and_registrations_cannot_change_availability_state() {
        assert!(init(
            &json!({
                "role":"offline-detection","timeoutMs":10,
                "inputTopics":bindings("offline-detection")
            })
            .to_string()
        ));
        let register = json!({"kind":"register","assetId":"sensor-1"});
        let tick = json!({"kind":"tick","assetId":"sensor-1"});
        for input in [register.clone(), tick.clone()] {
            assert!(
                <Module as Guest>::process(message_on("factory/availability-readings", input))
                    .is_err()
            );
        }
        assert_eq!(
            output_on("factory/availability-ticks", tick.clone(), 0)["kind"],
            "pending"
        );
        assert_eq!(
            output_on("factory/availability-registers", register.clone(), 1)["kind"],
            "pending"
        );
        for input in [register.clone(), tick.clone()] {
            assert!(process_at(message_on("factory/availability-readings", input), 1000).is_err());
        }
        // Repeated trusted registration must not refresh the offline deadline.
        assert_eq!(
            output_on("factory/availability-registers", register.clone(), 9)["kind"],
            "pending"
        );
        assert_eq!(
            output_on("factory/availability-ticks", tick.clone(), 11)["state"],
            "offline"
        );
        // A restarted graph recovers the expected roster from the next cycle.
        assert!(init(
            &json!({
                "role":"offline-detection","timeoutMs":10,
                "inputTopics":bindings("offline-detection")
            })
            .to_string()
        ));
        output_on("factory/availability-registers", register, 20);
        assert_eq!(
            output_on("factory/availability-ticks", tick, 30)["state"],
            "offline"
        );
    }

    #[test]
    fn all_new_roles_reject_unknown_kinds_and_topic_mismatches() {
        for role in [
            "report-by-exception",
            "stable-alarm",
            "offline-detection",
            "running-total",
            "smooth-readings",
        ] {
            let topics = bindings(role);
            assert!(init(&json!({"role":role,"inputTopics":topics}).to_string()));
            for (kind, topic) in &topics {
                for wrong_topic in [
                    "factory/input",
                    "other/smoothing-readings",
                    "factory/total-readings/extra",
                ] {
                    assert!(<Module as Guest>::process(message_on(
                        wrong_topic,
                        json!({"kind":kind})
                    ))
                    .is_err());
                }
                for wrong_kind in ["unknown", "model", "prediction"] {
                    assert!(<Module as Guest>::process(message_on(
                        topic,
                        json!({"kind":wrong_kind})
                    ))
                    .is_err());
                }
                for (other_kind, other_topic) in &topics {
                    if kind != other_kind {
                        assert!(<Module as Guest>::process(message_on(
                            other_topic,
                            json!({"kind":kind})
                        ))
                        .is_err());
                    }
                }
            }
        }
    }

    #[test]
    fn custom_full_topics_are_exact_and_do_not_use_suffix_authorization() {
        assert!(init(
            r#"{"role":"smooth-readings","inputTopics":{"reading":"tenant/custom"}} "#
        ));
        let input =
            json!({"kind":"reading","assetId":"sensor-1","messageId":"r0","sequence":0,"value":10});
        assert!(process_at(message_on("factory/custom", input.clone()), 1000).is_err());
        assert!(process_at(message_on("tenant/custom/extra", input.clone()), 0).is_err());
        assert_eq!(output_on("tenant/custom", input, 0)["smoothedValue"], 10.0);
    }

    #[test]
    fn wrapper_rejects_malformed_payloads_before_dispatch() {
        assert!(init(
            r#"{"role":"smooth-readings","inputTopics":{"reading":"factory/smoothing-readings"}}"#
        ));
        for payload in [
            b"not JSON".to_vec(),
            b"[]".to_vec(),
            b"null".to_vec(),
            b"{}".to_vec(),
            br#"{"kind":1}"#.to_vec(),
            vec![b' '; 65_537],
        ] {
            let DataModel::Message(mut input) = message(Value::Null) else {
                panic!()
            };
            input.payload = BufferOrBytes::Bytes(payload);
            assert!(process_at(DataModel::Message(input), 1000).is_err());
        }
        assert_eq!(
            output_on(
                "factory/smoothing-readings",
                json!({"kind":"reading","assetId":"sensor-1","messageId":"r0","sequence":0,"value":10}),
                0
            )["smoothedValue"],
            10.0
        );
    }
}
