// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use module_dataflow_patterns::{Config, Engine};
use serde_json::{json, Value};

fn settings(role: &str) -> Value {
    match role {
        "fit-linear-model" => json!({"role":role,"maxAssets":2,"fit":{
            "epoch":1,"featureCount":2,"minSamples":4,"maxSamples":8,
            "lookbackMs":1000,"maxCondition":1000000}}),
        _ => json!({"role":role,"maxAssets":2,"recommendation":{
            "epoch":1,"modelVersion":7,"gain":-0.5,
            "minValue":0,"maxValue":10,"maxStep":2,"maxAgeMs":1000}}),
    }
}
fn engine(config: Value) -> Engine {
    Engine::new(Config::parse(&config.to_string()).unwrap()).unwrap()
}
fn process(e: &mut Engine, v: Value, now: u64) -> Result<Value, String> {
    e.process(v.to_string().as_bytes(), now)
}
fn sample(i: u64, x: f64, z: f64) -> Value {
    json!({"kind":"sample","assetId":"sensor-a","sampleId":format!("s-{i}"),
        "epoch":1,"sequence":i,"modelVersion":7,"sampledAt":"1970-01-01T00:00:01Z",
        "features":[x,z],"target":3.0*x-2.0*z+5.0})
}
fn decision(i: u64) -> Value {
    json!({"kind":"decision","assetId":"sensor-a","decisionId":format!("d-{i}"),
        "epoch":1,"sequence":i,"modelVersion":7,"sampledAt":"1970-01-01T00:00:01Z",
        "currentValue":5,"error":2})
}
fn close(value: &Value, expected: f64) {
    assert!(
        (value.as_f64().unwrap() - expected).abs() < 1e-8,
        "{value} != {expected}"
    );
}
fn train(e: &mut Engine) -> Value {
    let mut out = Value::Null;
    for (i, (x, z)) in [(0., 0.), (1., 0.), (0., 1.), (2., 3.), (4., 1.), (-2., 4.)]
        .into_iter()
        .enumerate()
    {
        out = process(e, sample(i as u64, x, z), 1000).unwrap();
    }
    out
}

#[test]
fn fits_two_features_with_intercept_metrics_and_unapproved_provenance() {
    let mut e = engine(settings("fit-linear-model"));
    let out = train(&mut e);
    assert_eq!(out["kind"], "modelCandidate");
    assert_eq!(out["approved"], false);
    assert!(out.get("modelVersion").is_none());
    assert_eq!(out["basisModelVersion"], 7);
    assert_eq!(out["sampleCount"], 6);
    assert_eq!(
        out["sampleIds"],
        json!(["s-0", "s-1", "s-2", "s-3", "s-4", "s-5"])
    );
    close(&out["coefficients"][0], 3.);
    close(&out["coefficients"][1], -2.);
    close(&out["intercept"], 5.);
    close(&out["rmse"], 0.);
    close(&out["rSquared"], 1.);
}

#[test]
fn rank_deficient_constant_and_ill_conditioned_designs_withhold_candidates() {
    for mode in 0..3 {
        let mut e = engine(settings("fit-linear-model"));
        let mut out = Value::Null;
        for i in 0..8 {
            let x = i as f64;
            let z = match mode {
                0 => 1.,
                1 => x * 2.,
                _ => x * 2. + if i % 2 == 0 { 1e-10 } else { 0. },
            };
            out = process(&mut e, sample(i, x, z), 1000).unwrap();
        }
        assert_eq!(out["kind"], "diagnostic");
        assert_eq!(out["code"], "rankDeficient");
    }
}

#[test]
fn minimum_samples_and_square_full_rank_fit() {
    let mut c = settings("fit-linear-model");
    c["fit"]["minSamples"] = json!(3);
    let mut e = engine(c);
    assert_eq!(
        process(&mut e, sample(1, 0., 0.), 1000).unwrap()["kind"],
        "pending"
    );
    assert_eq!(
        process(&mut e, sample(2, 1., 0.), 1000).unwrap()["kind"],
        "pending"
    );
    let out = process(&mut e, sample(3, 0., 1.), 1000).unwrap();
    close(&out["intercept"], 5.);
    close(&out["coefficients"][0], 3.);
}

#[test]
fn constant_target_has_null_r_squared_and_finite_fit() {
    let mut e = engine(settings("fit-linear-model"));
    let mut out = Value::Null;
    for (i, (x, z)) in [(0., 0.), (1., 0.), (0., 1.), (2., 3.)]
        .into_iter()
        .enumerate()
    {
        let mut s = sample(i as u64, x, z);
        s["target"] = json!(4.);
        out = process(&mut e, s, 1000).unwrap();
    }
    assert!(out["rSquared"].is_null());
    close(&out["intercept"], 4.);
    close(&out["coefficients"][0], 0.);
}

#[test]
fn samples_bound_lookback_capacity_and_replay_watermark() {
    let mut c = settings("fit-linear-model");
    c["fit"]["maxSamples"] = json!(4);
    let mut e = engine(c);
    let out = train(&mut e);
    assert_eq!(out["sampleCount"], 4);
    assert_eq!(out["sampleIds"], json!(["s-2", "s-3", "s-4", "s-5"]));
    assert!(process(&mut e, sample(0, 0., 0.), 1000).is_err());
    let mut s = sample(6, 5., 7.);
    s["sampledAt"] = json!("1970-01-01T00:00:02.001Z");
    assert_eq!(process(&mut e, s, 2001).unwrap()["kind"], "pending");
}

#[test]
fn lookback_inclusive_and_expired_samples_do_not_refresh_on_retries() {
    let mut e = engine(settings("fit-linear-model"));
    let s = sample(1, 0., 0.);
    process(&mut e, s.clone(), 1000).unwrap();
    assert_eq!(
        process(&mut e, s.clone(), 2000).unwrap()["code"],
        "duplicateSample"
    );
    assert!(process(&mut e, s, 2001).is_err());
    let mut next = sample(2, 1., 0.);
    next["sampledAt"] = json!("1970-01-01T00:00:02.001Z");
    assert_eq!(process(&mut e, next, 2001).unwrap()["kind"], "pending");
}

#[test]
fn duplicate_conflict_epoch_version_sequence_and_time_are_atomic() {
    let mut e = engine(settings("fit-linear-model"));
    let s = sample(1, 0., 0.);
    process(&mut e, s.clone(), 1000).unwrap();
    assert_eq!(
        process(&mut e, s.clone(), 1000).unwrap()["code"],
        "duplicateSample"
    );
    let mut bad = s.clone();
    bad["target"] = json!(99);
    assert_eq!(
        process(&mut e, bad, 1000).unwrap()["code"],
        "conflictingSample"
    );
    for (field, value) in [
        ("epoch", json!(2)),
        ("modelVersion", json!(8)),
        ("sequence", json!(0)),
        ("sampledAt", json!("1970-01-01T00:00:00.999Z")),
        ("sampledAt", json!("1970-01-01T00:00:01.001Z")),
    ] {
        let mut bad = sample(2, 1., 0.);
        bad[field] = value;
        assert!(process(&mut e, bad, 1000).is_err(), "{field}");
    }
    assert_eq!(
        process(&mut e, sample(2, 1., 0.), 1000).unwrap()["kind"],
        "pending"
    );
}

#[test]
fn strict_input_schema_rejects_false_approvals_and_nonfinite_or_invalid_values() {
    for role in ["fit-linear-model", "bounded-recommendation"] {
        let mut e = engine(settings(role));
        let valid = if role == "fit-linear-model" {
            sample(1, 0., 0.)
        } else {
            decision(1)
        };
        for (field, value) in [
            ("approved", json!(true)),
            ("epoch", json!(0)),
            ("modelVersion", json!(0)),
            ("sequence", json!(-1)),
            ("assetId", json!("")),
            ("sampledAt", json!("1970-01-01T00:00:01.000001Z")),
        ] {
            let mut bad = valid.clone();
            bad[field] = value;
            assert!(process(&mut e, bad, 1000).is_err(), "{role} {field}");
        }
        let mut bad = valid.clone();
        bad[if role == "fit-linear-model" {
            "target"
        } else {
            "error"
        }] = json!(1e101);
        assert!(process(&mut e, bad, 1000).is_err());
        assert!(e.process(br#"{"target":NaN}"#, 1000).is_err());
        assert!(e.process(br#"{"target":1e400}"#, 1000).is_err());
        assert!(process(&mut e, valid, 1000).is_ok());
    }
}

#[test]
fn asset_capacity_is_bounded_and_assets_are_isolated() {
    for role in ["fit-linear-model", "bounded-recommendation"] {
        let mut e = engine(settings(role));
        for (i, asset) in ["a", "b", "c"].into_iter().enumerate() {
            let mut v = if role == "fit-linear-model" {
                sample(1, 0., 0.)
            } else {
                decision(1)
            };
            v["assetId"] = json!(asset);
            assert_eq!(process(&mut e, v, 1000).is_ok(), i < 2);
        }
    }
}

#[test]
fn recommendations_are_signed_bounded_nonactuating_and_never_approved() {
    for (current, error, expected, limited) in [
        (5., 2., 4., false),
        (5., 100., 3., true),
        (5., -100., 7., true),
        (0., 5., 0., true),
        (10., -5., 10., true),
        (5., 0., 5., false),
    ] {
        let mut e = engine(settings("bounded-recommendation"));
        let mut d = decision(1);
        d["currentValue"] = json!(current);
        d["error"] = json!(error);
        let out = process(&mut e, d, 1000).unwrap();
        close(&out["recommendedValue"], expected);
        assert_eq!(out["limited"], limited);
        assert_eq!(out["approved"], false);
        assert_eq!(out["actuation"], false);
    }
}

#[test]
fn representable_delta_cannot_exceed_max_step_and_rejection_is_atomic() {
    let mut c = settings("bounded-recommendation");
    c["recommendation"]["gain"] = json!(1);
    c["recommendation"]["maxStep"] = json!(1.5);
    c["recommendation"]["maxValue"] = json!(1e17);
    let mut e = engine(c);
    let mut d = decision(1);
    d["currentValue"] = json!(1e16);
    d["error"] = json!(1.5);
    assert!(process(&mut e, d.clone(), 1000).is_err());
    d["error"] = json!(0);
    let out = process(&mut e, d, 1000).unwrap();
    close(&out["delta"], 0.);
}

#[test]
fn recommendation_freshness_identity_version_replay_and_bounds_fail_closed() {
    let mut e = engine(settings("bounded-recommendation"));
    let d = decision(1);
    process(&mut e, d.clone(), 1000).unwrap();
    assert_eq!(
        process(&mut e, d.clone(), 2000).unwrap()["code"],
        "duplicateDecision"
    );
    let mut bad = d;
    bad["error"] = json!(3);
    assert_eq!(
        process(&mut e, bad, 2000).unwrap()["code"],
        "conflictingDecision"
    );
    for (field, value) in [
        ("currentValue", json!(11)),
        ("currentValue", json!(-1)),
        ("modelVersion", json!(8)),
        ("epoch", json!(2)),
        ("sequence", json!(1)),
        ("sampledAt", json!("1970-01-01T00:00:02.001Z")),
    ] {
        let mut bad = decision(2);
        bad[field] = value;
        assert!(process(&mut e, bad, 2000).is_err(), "{field}");
    }
    assert!(process(&mut e, decision(2), 2001).is_err());
    let mut valid = decision(2);
    valid["sampledAt"] = json!("1970-01-01T00:00:02.001Z");
    assert_eq!(
        process(&mut e, valid, 2001).unwrap()["kind"],
        "recommendation"
    );
}

#[test]
fn restart_is_volatile_and_new_epoch_rejects_old_inputs() {
    for role in ["fit-linear-model", "bounded-recommendation"] {
        let c = settings(role);
        let v = if role == "fit-linear-model" {
            sample(1, 0., 0.)
        } else {
            decision(1)
        };
        let mut e = engine(c.clone());
        process(&mut e, v.clone(), 1000).unwrap();
        let mut restarted = engine(c.clone());
        assert!(process(&mut restarted, v.clone(), 1000).is_ok());
        let mut next = c;
        next[if role == "fit-linear-model" {
            "fit"
        } else {
            "recommendation"
        }]["epoch"] = json!(2);
        assert!(process(&mut engine(next), v, 1000).is_err());
    }
}

#[test]
fn configurations_reject_under_determined_or_unbounded_training_and_bad_limits() {
    for (field, value) in [
        ("featureCount", json!(0)),
        ("featureCount", json!(9)),
        ("minSamples", json!(2)),
        ("maxSamples", json!(3)),
        ("maxSamples", json!(1025)),
        ("lookbackMs", json!(0)),
        ("lookbackMs", json!(86400001)),
        ("maxCondition", json!(0.9)),
        ("maxCondition", json!(1e9)),
        ("epoch", json!(0)),
    ] {
        let mut c = settings("fit-linear-model");
        c["fit"][field] = value;
        assert!(Config::parse(&c.to_string()).is_err(), "{field}");
    }

    for (field, value) in [
        ("minValue", json!(11)),
        ("maxStep", json!(0)),
        ("maxAgeMs", json!(0)),
        ("modelVersion", json!(0)),
        ("gain", json!(1e101)),
    ] {
        let mut c = settings("bounded-recommendation");
        c["recommendation"][field] = value;
        assert!(Config::parse(&c.to_string()).is_err(), "{field}");
    }
    for role in ["fit-linear-model", "bounded-recommendation"] {
        assert!(Config::parse(&json!({"role":role}).to_string()).is_err());
        let mut c = settings(role);
        c["maxAssets"] = json!(129);
        assert!(Config::parse(&c.to_string()).is_err());
    }
}

fn compare(actual: &Value, expected: &Value) {
    match (actual, expected) {
        (Value::Object(a), Value::Object(b)) => {
            assert_eq!(a.keys().collect::<Vec<_>>(), b.keys().collect::<Vec<_>>());
            for (key, value) in b {
                compare(&a[key], value);
            }
        }
        (Value::Array(a), Value::Array(b)) => {
            assert_eq!(a.len(), b.len());
            for (x, y) in a.iter().zip(b) {
                compare(x, y);
            }
        }
        (Value::Number(a), Value::Number(b)) => {
            assert!((a.as_f64().unwrap() - b.as_f64().unwrap()).abs() < 1e-8)
        }
        _ => assert_eq!(actual, expected),
    }
}

#[test]
fn complete_synthetic_fixtures_match_documented_payloads() {
    for text in [
        include_str!("../fixtures/fit-linear-model.json"),
        include_str!("../fixtures/bounded-recommendation.json"),
    ] {
        let fixture: Value = serde_json::from_str(text).unwrap();
        let mut e = engine(fixture["configuration"].clone());
        for step in fixture["steps"].as_array().unwrap() {
            let out = process(
                &mut e,
                step["input"].clone(),
                step["nowMs"].as_u64().unwrap(),
            )
            .unwrap();
            if step["expected"].is_null() {
                assert!(matches!(
                    out["kind"].as_str(),
                    Some("pending" | "diagnostic")
                ));
            } else {
                compare(&out, &step["expected"]);
            }
        }
    }
}

#[test]
fn decimal_constant_targets_never_claim_defined_r_squared() {
    let mut c = settings("fit-linear-model");
    c["fit"]["featureCount"] = json!(1);
    c["fit"]["minSamples"] = json!(6);
    let mut e = engine(c);
    let mut out = Value::Null;
    for i in 0..6 {
        let mut s = sample(i, 0., 0.);
        s["features"] = json!([i]);
        s["target"] = json!(0.1);
        out = process(&mut e, s, 1000).unwrap();
    }
    assert_eq!(out["kind"], "modelCandidate");
    assert!(out["rSquared"].is_null());
    close(&out["intercept"], 0.1);
}

#[test]
fn tiny_features_and_residual_metrics_do_not_underflow_when_squared() {
    for tiny_features in [true, false] {
        let mut c = settings("fit-linear-model");
        c["fit"]["featureCount"] = json!(1);
        c["fit"]["minSamples"] = json!(3);
        let mut e = engine(c);
        let mut out = Value::Null;
        for i in 0..3 {
            let mut s = sample(i, 0., 0.);
            s["features"] = json!([i as f64 * if tiny_features { 1e-200 } else { 1.0 }]);
            s["target"] = json!(if tiny_features {
                i as f64 * 1e-200
            } else if i == 1 {
                1e-200
            } else {
                0.0
            });
            out = process(&mut e, s, 1000).unwrap();
        }
        assert_eq!(out["kind"], "modelCandidate");
        if tiny_features {
            close(&out["coefficients"][0], 1.);
        } else {
            let rmse = out["rmse"].as_f64().unwrap();
            assert!((rmse / 1e-200 - 2f64.sqrt() / 3.).abs() < 1e-10);
            close(&out["rSquared"], 0.);
        }
    }
}

#[test]
fn supports_eight_orthogonal_features_without_assuming_sensor_names() {
    let mut c = settings("fit-linear-model");
    c["fit"]["featureCount"] = json!(8);
    c["fit"]["minSamples"] = json!(16);
    c["fit"]["maxSamples"] = json!(16);
    let mut e = engine(c);
    let mut out = Value::Null;
    for i in 0..16u64 {
        let features: Vec<f64> = (1..=8u64)
            .map(|j| {
                if (i & j).count_ones() % 2 == 0 {
                    1.
                } else {
                    -1.
                }
            })
            .collect();
        let target = 2.0
            + features
                .iter()
                .enumerate()
                .map(|(j, x)| (j + 1) as f64 * x)
                .sum::<f64>();
        let mut s = sample(i, 0., 0.);
        s["features"] = json!(features);
        s["target"] = json!(target);
        out = process(&mut e, s, 1000).unwrap();
    }
    assert_eq!(out["featureCount"], 8);
    for j in 0..8 {
        close(&out["coefficients"][j], (j + 1) as f64);
    }
    close(&out["intercept"], 2.);
}

#[test]
fn subnormal_targets_are_normalized_before_solving() {
    let mut c = settings("fit-linear-model");
    c["fit"]["featureCount"] = json!(1);
    c["fit"]["minSamples"] = json!(64);
    c["fit"]["maxSamples"] = json!(64);
    let mut e = engine(c);
    let smallest = f64::from_bits(1);
    let mut out = Value::Null;
    for i in 0..64 {
        let x = if i % 2 == 0 { 1.0 } else { -1.0 };
        let mut s = sample(i, 0., 0.);
        s["features"] = json!([x]);
        s["target"] = json!(x * smallest);
        out = process(&mut e, s, 1000).unwrap();
    }
    assert_eq!(out["kind"], "modelCandidate");
    assert_eq!(out["coefficients"][0].as_f64().unwrap(), smallest);
    assert_eq!(out["intercept"].as_f64().unwrap(), 0.0);
    assert_eq!(out["rmse"].as_f64().unwrap(), 0.0);
    close(&out["rSquared"], 1.0);
}
