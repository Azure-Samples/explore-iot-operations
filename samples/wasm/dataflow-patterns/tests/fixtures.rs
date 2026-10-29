// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use module_dataflow_patterns::{Config, Engine};
use serde_json::Value;

#[test]
fn customer_publish_sequences_match_expected_graph_payloads() {
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
        let fixture: Value = serde_json::from_str(text).unwrap();
        let config = Config::parse(&fixture["configuration"].to_string()).unwrap();
        let mut engine = Engine::new(config).unwrap();
        for step in fixture["steps"].as_array().unwrap() {
            let out = engine
                .process(
                    step["input"].to_string().as_bytes(),
                    step["nowMs"].as_u64().unwrap(),
                )
                .unwrap();
            let delivered = match out["kind"].as_str() {
                Some("pending" | "modelApplied" | "diagnostic") => Value::Null,
                _ => out,
            };
            assert_eq!(delivered, step["expected"], "input: {}", step["input"]);
        }
    }
}

#[test]
fn engine_rejects_invalid_json_payload_limits_and_backwards_clock() {
    let mut engine = Engine::new(Config::parse(r#"{"role":"correlate-by-id"}"#).unwrap()).unwrap();
    for payload in [
        b"null".as_slice(),
        b"[]",
        b"{",
        b"{\"n\":NaN}",
        b"{\"n\":1e400}",
    ] {
        assert!(engine.process(payload, 1000).is_err());
    }
    assert!(engine.process(&vec![b' '; 65537], 1000).is_err());
    assert!(engine
        .process(br#"{"kind":"tick","assetId":"a"}"#, 999)
        .is_err());
}

#[test]
fn configuration_limits_and_timestamp_precision_are_explicit() {
    for config in [
        r#"{"role":"align-by-time","maxAssets":0}"#,
        r#"{"role":"align-by-time","maxPendingPerAsset":4097}"#,
        r#"{"role":"align-by-time","pendingTtlMs":2000}"#,
        r#"{"role":"align-by-time","unknown":1}"#,
        r#"{"role":"align-by-time","initialModels":[{"assetId":"a","modelVersion":7,"speedCoefficient":2,"temperatureCoefficient":0.5,"intercept":175}]}"#,
        r#"{"role":"versioned-predictor","initialModels":[{"assetId":"a","modelVersion":0,"speedCoefficient":2,"temperatureCoefficient":0.5,"intercept":175}]}"#,
    ] {
        assert!(Config::parse(config).is_err(), "{config}");
    }
    assert!(module_dataflow_patterns::common::timestamp("2026-10-19T10:00:00.000001Z").is_err());
    assert_eq!(
        module_dataflow_patterns::common::timestamp("2026-10-19T11:00:00+01:00").unwrap(),
        module_dataflow_patterns::common::timestamp("2026-10-19T10:00:00Z").unwrap()
    );
}
