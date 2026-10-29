// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use module_dataflow_patterns::{Config, Engine};
use serde_json::{json, Value};

const ROLES: [&str; 5] = [
    "report-by-exception",
    "stable-alarm",
    "offline-detection",
    "running-total",
    "smooth-readings",
];

fn seed(asset: &str, total: f64, version: u64, epoch: u64, sequence: u64) -> Value {
    json!({
        "assetId": asset, "total": total, "stateVersion": version,
        "epoch": epoch, "lastSequence": sequence
    })
}

fn configuration(role: &str, options: Value) -> Value {
    let mut config = json!({"role": role});
    if role == "running-total" {
        config["initialStates"] = json!([seed("a", 0.0, 0, 0, 0), seed("b", 0.0, 0, 0, 0)]);
    }
    for (key, value) in options.as_object().unwrap() {
        config[key] = value.clone();
    }
    config
}

fn engine(role: &str, options: Value) -> Engine {
    let config = configuration(role, options);
    Engine::new(Config::parse(&config.to_string()).unwrap()).unwrap()
}

fn process(engine: &mut Engine, input: &Value, now_ms: u64) -> Value {
    engine
        .process(&serde_json::to_vec(input).unwrap(), now_ms)
        .unwrap_or_else(|error| panic!("input {input} at {now_ms}: {error}"))
}

fn rejects(engine: &mut Engine, input: &Value, now_ms: u64) {
    assert!(
        engine
            .process(&serde_json::to_vec(input).unwrap(), now_ms)
            .is_err(),
        "expected schema/arithmetic error for {input} at {now_ms}"
    );
}

fn reading(asset: &str, id: &str, sequence: u64, value: f64) -> Value {
    json!({
        "kind": "reading", "assetId": asset, "messageId": id,
        "sequence": sequence, "value": value
    })
}

fn role_reading(role: &str, asset: &str, id: &str, sequence: u64, value: f64) -> Value {
    let mut input = reading(asset, id, sequence, value);
    if role == "running-total" {
        input["epoch"] = json!(0);
    }
    input
}

fn tick(asset: &str) -> Value {
    json!({"kind": "tick", "assetId": asset})
}

fn reset(id: &str, sequence: u64, version: u64) -> Value {
    json!({
        "kind": "reset", "assetId": "a", "resetId": id,
        "sequence": sequence, "expectedStateVersion": version
    })
}

fn diagnostic(output: &Value, code: &str) {
    assert_eq!(output["kind"], "diagnostic", "{output}");
    assert_eq!(output["code"], code, "{output}");
}

fn capacity(output: &Value) {
    diagnostic(output, "capacity");
}

fn pending(output: &Value) {
    assert_eq!(output["kind"], "pending", "{output}");
}

fn derived(input: &Value, fields: Value) -> Value {
    let mut expected = input.clone();
    for (key, value) in fields.as_object().unwrap() {
        expected[key] = value.clone();
    }
    expected
}

fn reported(input: &Value, reason: &str, now: u64, received: u64, fresh: bool) -> Value {
    derived(
        input,
        json!({
            "kind": "reported", "reason": reason, "emittedAtMs": now,
            "receivedAtMs": received, "observationAgeMs": now - received,
            "isFreshMeasurement": fresh
        }),
    )
}

fn alarm(
    input: &Value,
    state: &str,
    threshold: f64,
    now: u64,
    received: u64,
    fresh: bool,
) -> Value {
    derived(
        input,
        json!({
            "kind": "alarm", "state": state, "reason": "thresholdSustained",
            "threshold": threshold, "emittedAtMs": now, "receivedAtMs": received,
            "observationAgeMs": now - received, "isFreshMeasurement": fresh
        }),
    )
}

fn availability(
    asset: &str,
    state: &str,
    reason: &str,
    now: u64,
    last_seen: Option<u64>,
    elapsed: u64,
) -> Value {
    json!({
        "kind": "availability", "assetId": asset, "state": state, "reason": reason,
        "emittedAtMs": now, "lastSeenAtMs": last_seen, "elapsedMs": elapsed
    })
}

#[test]
fn generic_role_defaults_construct_and_accept_their_first_reading() {
    for role in ROLES {
        let mut e = engine(role, json!({}));
        let input = role_reading(role, "a", "first", 1, 10.0);
        let output = process(&mut e, &input, 100);
        match role {
            "report-by-exception" => {
                assert_eq!(output, reported(&input, "initial", 100, 100, true))
            }
            "smooth-readings" => assert_eq!(
                output,
                derived(
                    &input,
                    json!({"kind":"smoothed","smoothedValue":10.0,"emittedAtMs":100})
                )
            ),
            "stable-alarm" => pending(&output),
            "offline-detection" => assert_eq!(
                output,
                availability("a", "online", "firstReading", 100, Some(100), 0)
            ),
            "running-total" => assert_eq!(
                output,
                derived(
                    &input,
                    json!({
                        "kind":"total","total":10.0,"stateVersion":1,
                        "epoch":0,"lastSequence":1,"emittedAtMs":100
                    })
                )
            ),
            _ => unreachable!(),
        }
    }
}

#[test]
fn configuration_rejects_irrelevant_role_specific_options_even_at_default_values() {
    let options = [
        ("deadband", json!(1), "report-by-exception"),
        ("heartbeatIntervalMs", json!(1000), "report-by-exception"),
        ("high", json!(80), "stable-alarm"),
        ("low", json!(70), "stable-alarm"),
        ("raiseForMs", json!(0), "stable-alarm"),
        ("clearForMs", json!(0), "stable-alarm"),
        ("maxObservationGapMs", json!(5000), "stable-alarm"),
        ("timeoutMs", json!(10000), "offline-detection"),
        ("alpha", json!(0.5), "smooth-readings"),
        ("initialStates", json!([]), "running-total"),
    ];
    for role in ROLES {
        for (name, value, owner) in &options {
            if role != *owner {
                let mut config = configuration(role, json!({}));
                config[*name] = value.clone();
                assert!(Config::parse(&config.to_string()).is_err(), "{config}");
            }
        }
    }
}

#[test]
fn configuration_rejects_invalid_numeric_bounds_and_types() {
    for role in ROLES {
        for (key, invalid) in [
            ("maxAssets", json!([0, 129, -1, 1.5, "1", null])),
            ("maxHistoryPerAsset", json!([0, -1, 1.5, "1", null])),
            ("maxUpdatesPerAsset", json!([0, -1, 1.5, "1", null])),
        ] {
            for value in invalid.as_array().unwrap() {
                let mut config = configuration(role, json!({}));
                config[key] = value.clone();
                assert!(Config::parse(&config.to_string()).is_err(), "{config}");
            }
        }
    }
    for (role, key, values) in [
        ("report-by-exception", "deadband", json!([0, -1, "1", null])),
        (
            "report-by-exception",
            "heartbeatIntervalMs",
            json!([0, -1, 86400001_u64, 1.5, null]),
        ),
        (
            "stable-alarm",
            "raiseForMs",
            json!([-1, 86400001_u64, 0.5, null]),
        ),
        (
            "stable-alarm",
            "clearForMs",
            json!([-1, 86400001_u64, 0.5, null]),
        ),
        (
            "stable-alarm",
            "maxObservationGapMs",
            json!([0, -1, 86400001_u64, 1.5, null]),
        ),
        (
            "offline-detection",
            "timeoutMs",
            json!([0, -1, 86400001_u64, 1.5, null]),
        ),
        (
            "smooth-readings",
            "alpha",
            json!([0, -0.1, 1.000001, "0.5", null]),
        ),
        ("stable-alarm", "high", json!(["80", null])),
        ("stable-alarm", "low", json!(["70", null])),
    ] {
        for value in values.as_array().unwrap() {
            let mut config = configuration(role, json!({}));
            config[key] = value.clone();
            assert!(Config::parse(&config.to_string()).is_err(), "{config}");
        }
    }
    for options in [
        json!({"low":80,"high":80}),
        json!({"low":81,"high":80}),
        json!({"low":70,"high":69}),
    ] {
        let config = configuration("stable-alarm", options);
        assert!(Config::parse(&config.to_string()).is_err(), "{config}");
    }
}

#[test]
fn configuration_accepts_documented_boundaries() {
    for (role, options) in [
        (
            "report-by-exception",
            json!({"deadband":f64::MIN_POSITIVE,"heartbeatIntervalMs":1}),
        ),
        (
            "report-by-exception",
            json!({"deadband":f64::MAX,"heartbeatIntervalMs":86400000}),
        ),
        (
            "stable-alarm",
            json!({"low":-2,"high":-1,"raiseForMs":0,"clearForMs":0,"maxObservationGapMs":1}),
        ),
        (
            "stable-alarm",
            json!({"raiseForMs":86400000,"clearForMs":86400000,"maxObservationGapMs":86400000}),
        ),
        ("offline-detection", json!({"timeoutMs":1})),
        ("offline-detection", json!({"timeoutMs":86400000})),
        ("smooth-readings", json!({"alpha":f64::MIN_POSITIVE})),
        ("smooth-readings", json!({"alpha":1})),
    ] {
        let _ = engine(role, options);
    }
    for role in ROLES {
        let _ = engine(role, json!({"maxAssets":128,"maxHistoryPerAsset":1}));
    }
    let _ = engine("running-total", json!({"maxUpdatesPerAsset":1}));
}

#[test]
fn nonfinite_configuration_numbers_are_rejected() {
    for (role, key) in [
        ("report-by-exception", "deadband"),
        ("stable-alarm", "high"),
        ("stable-alarm", "low"),
        ("smooth-readings", "alpha"),
    ] {
        for literal in ["1e400", "-1e400", "NaN", "Infinity"] {
            let text = format!(r#"{{"role":"{role}","{key}":{literal}}}"#);
            assert!(Config::parse(&text).is_err(), "{text}");
        }
    }
}

#[test]
fn all_roles_retain_exact_payloads_and_reject_conflicts_and_stale_sequences() {
    for role in ROLES {
        let mut e = engine(role, json!({}));
        let mut first = role_reading(role, "a", "one", 1, 10.0);
        first["metadata"] = json!({"sensor":"s1","tags":[1,2]});
        process(&mut e, &first, 100);
        diagnostic(&process(&mut e, &first, 101), "duplicate");
        for changed in [
            derived(&first, json!({"value":11})),
            derived(&first, json!({"sequence":2})),
            derived(&first, json!({"metadata":{"sensor":"s2","tags":[1,2]}})),
            derived(&first, json!({"extra":true})),
        ] {
            diagnostic(&process(&mut e, &changed, 102), "conflict");
        }
        for sequence in [0, 1] {
            let stale = role_reading(role, "a", "other", sequence, 100.0);
            diagnostic(&process(&mut e, &stale, 103), "staleReading");
        }
        let second = role_reading(role, "a", "two", 2, 20.0);
        let output = process(&mut e, &second, 104);
        assert_ne!(output["kind"], "diagnostic", "{role}: {output}");
        if role == "running-total" {
            assert_eq!(output["total"], 30.0);
            assert_eq!(output["stateVersion"], 2);
        } else if role == "smooth-readings" {
            assert_eq!(output["smoothedValue"], 15.0);
        }
        diagnostic(&process(&mut e, &first, 105), "duplicate");
    }
}

#[test]
fn nonrunning_roles_accept_sequence_zero_and_all_roles_accept_u64_watermarks() {
    for role in ROLES {
        let mut e = engine(role, json!({}));
        if role != "running-total" {
            let zero = reading("a", "zero", 0, 1.0);
            assert_ne!(process(&mut e, &zero, 0)["kind"], "diagnostic");
            diagnostic(
                &process(&mut e, &reading("a", "other-zero", 0, 2.0), 0),
                "staleReading",
            );
        }
        let last = role_reading(role, "a", "last", u64::MAX, 2.0);
        assert_ne!(process(&mut e, &last, 1)["kind"], "diagnostic");
        diagnostic(&process(&mut e, &last, 2), "duplicate");
        diagnostic(
            &process(
                &mut e,
                &role_reading(role, "a", "older", u64::MAX - 1, 9.0),
                3,
            ),
            "staleReading",
        );
    }
}

#[test]
fn reading_schema_errors_are_atomic_for_every_role() {
    for role in ROLES {
        for (field, invalid_values) in [
            ("assetId", json!([null, 4, ""])),
            ("messageId", json!([null, 4, ""])),
            ("sequence", json!([null, -1, 1.5, "1"])),
            ("value", json!([null, "1", true, {}, []])),
        ] {
            for value in invalid_values.as_array().unwrap() {
                let mut e = engine(role, json!({}));
                let valid = role_reading(role, "a", "one", 1, 10.0);
                let mut invalid = valid.clone();
                invalid[field] = value.clone();
                rejects(&mut e, &invalid, 100);
                assert_ne!(process(&mut e, &valid, 100)["kind"], "diagnostic");
            }
            let mut e = engine(role, json!({}));
            let mut invalid = role_reading(role, "a", "one", 1, 10.0);
            invalid.as_object_mut().unwrap().remove(field);
            rejects(&mut e, &invalid, 100);
        }
        for kind in [json!(null), json!(42), json!("not-a-kind")] {
            let mut e = engine(role, json!({}));
            let mut invalid = role_reading(role, "a", "one", 1, 10.0);
            invalid["kind"] = kind;
            rejects(&mut e, &invalid, 100);
        }
        let mut e = engine(role, json!({}));
        let mut invalid = role_reading(role, "a", "one", 1, 10.0);
        invalid.as_object_mut().unwrap().remove("kind");
        rejects(&mut e, &invalid, 100);
        for literal in ["NaN", "Infinity", "1e400", "-1e400"] {
            let epoch = if role == "running-total" {
                r#","epoch":0"#
            } else {
                ""
            };
            let text = format!(
                r#"{{"kind":"reading","assetId":"a","messageId":"one","sequence":1,"value":{literal}{epoch}}}"#
            );
            assert!(e.process(text.as_bytes(), 100).is_err(), "{role}: {text}");
        }
    }
}

#[test]
fn derived_fields_cannot_be_injected_into_readings() {
    for role in ROLES {
        let mut fields = vec!["emittedAtMs"];
        match role {
            "report-by-exception" => fields.extend([
                "reason",
                "receivedAtMs",
                "observationAgeMs",
                "isFreshMeasurement",
            ]),
            "stable-alarm" => fields.extend([
                "state",
                "reason",
                "threshold",
                "receivedAtMs",
                "observationAgeMs",
                "isFreshMeasurement",
            ]),
            "offline-detection" => fields.extend(["state", "reason", "lastSeenAtMs", "elapsedMs"]),
            "running-total" => fields.extend(["total", "stateVersion", "lastSequence"]),
            "smooth-readings" => fields.push("smoothedValue"),
            _ => unreachable!(),
        }
        for field in fields {
            let mut e = engine(role, json!({}));
            let valid = role_reading(role, "a", "one", 1, 10.0);
            let mut forged = valid.clone();
            forged[field] = json!(0);
            rejects(&mut e, &forged, 100);
            assert_ne!(process(&mut e, &valid, 100)["kind"], "diagnostic");
        }
    }
}

#[test]
fn history_evicts_oldest_accepted_payload_without_losing_sequence_watermark() {
    for role in ROLES {
        let mut e = engine(role, json!({"maxHistoryPerAsset":2}));
        let first = role_reading(role, "a", "one", 1, 10.0);
        let second = role_reading(role, "a", "two", 2, 20.0);
        process(&mut e, &first, 0);
        process(&mut e, &second, 1);
        let third = role_reading(role, "a", "three", 100, 999.0);
        assert_ne!(process(&mut e, &third, 2)["kind"], "diagnostic");
        diagnostic(&process(&mut e, &third, 3), "duplicate");
        diagnostic(&process(&mut e, &first, 4), "staleReading");
        diagnostic(
            &process(&mut e, &derived(&second, json!({"value":21})), 5),
            "conflict",
        );
        process(&mut e, &tick("a"), 100_000_000);
        diagnostic(&process(&mut e, &first, 100_000_001), "staleReading");
        diagnostic(&process(&mut e, &third, 100_000_002), "duplicate");
        let other = role_reading(role, "b", "three", 1, 7.0);
        assert_ne!(process(&mut e, &other, 100_000_003)["kind"], "diagnostic");
    }
}

#[test]
fn default_history_keeps_last_256_while_streaming_over_ten_times_capacity() {
    for role in ROLES {
        let mut e = engine(role, json!({}));
        for sequence in 1..=2561 {
            let value = if sequence % 2 == 0 { 100.0 } else { 0.0 };
            let input = role_reading(role, "a", &format!("m{sequence}"), sequence, value);
            let output = process(&mut e, &input, sequence * 50);
            match role {
                "report-by-exception" => assert_eq!(output["kind"], "reported"),
                "stable-alarm" if sequence > 1 => assert_eq!(output["kind"], "alarm"),
                "stable-alarm" => pending(&output),
                "offline-detection" if sequence == 1 => assert_eq!(output["state"], "online"),
                "offline-detection" => pending(&output),
                "smooth-readings" => assert_eq!(output["kind"], "smoothed"),
                "running-total" => {
                    assert_eq!(output["kind"], "total");
                    assert_eq!(output["total"], (sequence / 2 * 100) as f64);
                    assert_eq!(output["stateVersion"], sequence);
                    assert_eq!(output["lastSequence"], sequence);
                }
                _ => unreachable!(),
            }
        }
        diagnostic(
            &process(
                &mut e,
                &role_reading(role, "a", "m2305", 2305, 0.0),
                128_051,
            ),
            "staleReading",
        );
        let retained = role_reading(role, "a", "m2306", 2306, 100.0);
        diagnostic(&process(&mut e, &retained, 128_052), "duplicate");
        diagnostic(
            &process(&mut e, &derived(&retained, json!({"value":99})), 128_053),
            "conflict",
        );
        if role == "offline-detection" {
            assert_eq!(
                process(&mut e, &tick("a"), 138_050),
                availability("a", "offline", "timeout", 138_050, Some(128_050), 10_000)
            );
        }
    }
}

#[test]
fn unknown_ticks_never_allocate_assets_and_assets_do_not_expire() {
    for role in ROLES {
        let options = if role == "running-total" {
            json!({"maxAssets":1,"initialStates":[seed("a",0.0,0,0,0)]})
        } else {
            json!({"maxAssets":1})
        };
        let mut e = engine(role, options);
        for n in 0..140 {
            pending(&process(&mut e, &tick(&format!("unknown-{n}")), n));
        }
        let first = role_reading(role, "a", "one", 1, 10.0);
        assert_ne!(process(&mut e, &first, 200)["kind"], "diagnostic");
        process(&mut e, &tick("a"), 100_000_000);
        diagnostic(&process(&mut e, &first, 100_000_001), "duplicate");
        let other = role_reading(role, "b", "one", 1, 1.0);
        let output = process(&mut e, &other, 100_000_002);
        if role == "running-total" {
            diagnostic(&output, "uninitializedAsset");
        } else {
            capacity(&output);
        }
        let next = role_reading(role, "a", "two", 2, 11.0);
        assert_ne!(process(&mut e, &next, 100_000_003)["kind"], "diagnostic");
    }
}

#[test]
fn default_asset_limit_is_128_and_running_seeds_count_toward_it() {
    for role in ROLES {
        let options = if role == "running-total" {
            let states: Vec<_> = (0..128)
                .map(|n| seed(&format!("asset-{n}"), 0.0, 0, 0, 0))
                .collect();
            json!({"initialStates":states})
        } else {
            json!({})
        };
        let mut e = engine(role, options);
        for n in 0..128 {
            let input = role_reading(role, &format!("asset-{n}"), "same-id", 1, 1.0);
            assert_ne!(process(&mut e, &input, n)["kind"], "diagnostic");
        }
        let extra = role_reading(role, "extra", "same-id", 1, 1.0);
        let output = process(&mut e, &extra, 128);
        if role == "running-total" {
            diagnostic(&output, "uninitializedAsset");
        } else {
            capacity(&output);
        }
    }
}

#[test]
fn timestamps_require_epoch_or_later_rfc3339_millisecond_precision() {
    for role in ROLES {
        for timestamp in [
            json!("1969-12-31T23:59:59.999Z"),
            json!("1970-01-01T00:00:00.000001Z"),
            json!("1970-01-01T00:00:00"),
            json!("not-a-time"),
            json!(0),
            json!(null),
        ] {
            let mut e = engine(role, json!({}));
            let input = role_reading(role, "a", "one", 1, 1.0);
            rejects(
                &mut e,
                &derived(&input, json!({"sampledAt":timestamp})),
                1000,
            );
            assert_ne!(process(&mut e, &input, 1000)["kind"], "diagnostic");
            rejects(
                &mut e,
                &derived(&tick("a"), json!({"sampledAt":timestamp})),
                1000,
            );
        }
        for timestamp in [
            "1970-01-01T00:00:00Z",
            "1970-01-01T00:00:00.000Z",
            "1970-01-01T01:00:00+01:00",
        ] {
            let mut e = engine(role, json!({}));
            let mut input = role_reading(role, "a", "one", 1, 1.0);
            input["sampledAt"] = json!(timestamp);
            assert_ne!(process(&mut e, &input, 1000)["kind"], "diagnostic");
        }
    }
}

#[test]
fn timestamps_enforce_skew_and_preserve_last_present_accepted_timestamp() {
    for role in ROLES {
        let mut e = engine(role, json!({"maxFutureSkewMs":100}));
        let first = derived(
            &role_reading(role, "a", "one", 1, 1.0),
            json!({"sampledAt":"1970-01-01T00:00:01.100Z"}),
        );
        process(&mut e, &first, 1000);
        let future = derived(
            &role_reading(role, "a", "two", 2, 2.0),
            json!({"sampledAt":"1970-01-01T00:00:01.101Z"}),
        );
        rejects(&mut e, &future, 1000);
        rejects(
            &mut e,
            &derived(&tick("a"), json!({"sampledAt":"1970-01-01T00:00:01.101Z"})),
            1000,
        );
        // An absent timestamp does not erase the last present timestamp.
        process(&mut e, &role_reading(role, "a", "two", 2, 2.0), 1000);
        let third = role_reading(role, "a", "three", 3, 3.0);
        diagnostic(
            &process(
                &mut e,
                &derived(&third, json!({"sampledAt":"1970-01-01T00:00:01.099Z"})),
                1000,
            ),
            "staleReading",
        );
        let equal = derived(&third, json!({"sampledAt":"1970-01-01T01:00:01.100+01:00"}));
        assert_ne!(process(&mut e, &equal, 1000)["kind"], "diagnostic");
        diagnostic(&process(&mut e, &first, 1000), "duplicate");
        // A high timestamp on a rejected stale reading must not poison the watermark.
        let stale = derived(
            &role_reading(role, "a", "stale", 2, 999.0),
            json!({"sampledAt":"1970-01-01T00:00:01.200Z"}),
        );
        diagnostic(&process(&mut e, &stale, 1100), "staleReading");
        let fourth = derived(
            &role_reading(role, "a", "four", 4, 4.0),
            json!({"sampledAt":"1970-01-01T00:00:01.100Z"}),
        );
        assert_ne!(process(&mut e, &fourth, 1100)["kind"], "diagnostic");
    }
}

#[test]
fn running_total_checkpoint_preserves_timestamp_watermark_across_omissions_and_reset() {
    let mut e = engine("running-total", json!({}));
    let first = derived(
        &role_reading("running-total", "a", "one", 1, 2.0),
        json!({"sampledAt":"1970-01-01T00:00:01Z"}),
    );
    assert_eq!(
        process(&mut e, &first, 1000)["lastSampledAt"],
        first["sampledAt"]
    );
    let checkpoint = process(&mut e, &reset("reset", 2, 1), 1000);
    assert_eq!(checkpoint["lastSampledAt"], first["sampledAt"]);
    let initial = json!({
        "assetId":"a", "total":checkpoint["total"], "stateVersion":checkpoint["stateVersion"],
        "epoch":checkpoint["epoch"], "lastSequence":checkpoint["lastSequence"],
        "lastSampledAt":checkpoint["lastSampledAt"]
    });
    let mut restored = engine("running-total", json!({"initialStates":[initial]}));
    let next = derived(&reading("a", "two", 3, 3.0), json!({"epoch":1}));
    let checkpoint = process(&mut restored, &next, 1000);
    assert_eq!(checkpoint["lastSampledAt"], first["sampledAt"]);
    let older = derived(
        &reading("a", "three", 4, 5.0),
        json!({"epoch":1,"sampledAt":"1970-01-01T00:00:00.999Z"}),
    );
    diagnostic(&process(&mut restored, &older, 1000), "staleReading");
    let fresh = derived(
        &reading("a", "three", 4, 5.0),
        json!({"epoch":1,"sampledAt":"1970-01-01T00:00:01Z"}),
    );
    assert_eq!(process(&mut restored, &fresh, 1000)["total"], 8.0);
    for invalid in [
        "invalid",
        "1969-12-31T23:59:59Z",
        "1970-01-01T00:00:00.000001Z",
    ] {
        let mut config = configuration("running-total", json!({}));
        config["initialStates"][0]["lastSampledAt"] = json!(invalid);
        assert!(Config::parse(&config.to_string()).is_err());
    }
}

#[test]
fn report_deadband_is_inclusive_and_uses_last_report_not_last_observation() {
    let mut e = engine("report-by-exception", json!({}));
    let cases = [
        (0, 10.0, Some("initial")),
        (1, 10.75, None),
        (2, 10.99, None),
        (3, 11.0, Some("change")),
        (4, 10.5, None),
        (5, 10.0, Some("change")),
        (6, 9.0, Some("change")),
    ];
    for (sequence, value, reason) in cases {
        let input = reading("a", &format!("m{sequence}"), sequence, value);
        let output = process(&mut e, &input, sequence);
        if let Some(reason) = reason {
            assert_eq!(output, reported(&input, reason, sequence, sequence, true));
        } else {
            pending(&output);
        }
    }
    pending(&process(&mut e, &tick("a"), 86_400_000));
}

#[test]
fn report_heartbeat_uses_latest_accepted_payload_and_resets_reported_baseline() {
    let mut e = engine(
        "report-by-exception",
        json!({"deadband":10,"heartbeatIntervalMs":100}),
    );
    let first = reading("a", "one", 0, 10.0);
    process(&mut e, &first, 1000);
    let latest = derived(
        &reading("a", "two", 1, 15.0),
        json!({"metadata":{"line":"L1"},"sampledAt":"1970-01-01T00:00:20Z"}),
    );
    pending(&process(&mut e, &latest, 1050));
    pending(&process(&mut e, &tick("a"), 1099));
    assert_eq!(
        process(&mut e, &tick("a"), 1100),
        reported(&latest, "heartbeat", 1100, 1050, false)
    );
    pending(&process(&mut e, &tick("a"), 1199));
    let next = reading("a", "three", 2, 24.0);
    pending(&process(&mut e, &next, 1199));
    assert_eq!(
        process(&mut e, &tick("a"), 1200),
        reported(&next, "heartbeat", 1200, 1199, false)
    );
    let changed = reading("a", "four", 3, 34.0);
    assert_eq!(
        process(&mut e, &changed, 1201),
        reported(&changed, "change", 1201, 1201, true)
    );
    pending(&process(&mut e, &tick("a"), 1300));
}

#[test]
fn report_rejected_readings_do_not_refresh_heartbeat_or_replace_latest() {
    let mut e = engine(
        "report-by-exception",
        json!({"deadband":100,"heartbeatIntervalMs":100,"maxHistoryPerAsset":2}),
    );
    let first = reading("a", "one", 1, 10.0);
    let latest = reading("a", "two", 2, 11.0);
    process(&mut e, &first, 0);
    pending(&process(&mut e, &latest, 10));
    diagnostic(&process(&mut e, &latest, 90), "duplicate");
    diagnostic(
        &process(&mut e, &derived(&latest, json!({"value":12})), 91),
        "conflict",
    );
    diagnostic(
        &process(&mut e, &reading("a", "stale", 1, 13.0), 92),
        "staleReading",
    );
    diagnostic(
        &process(&mut e, &reading("a", "stale-again", 2, 14.0), 93),
        "staleReading",
    );
    assert_eq!(
        process(&mut e, &tick("a"), 100),
        reported(&latest, "heartbeat", 100, 10, false)
    );
}

#[test]
fn report_assets_have_independent_baselines_and_heartbeat_clocks() {
    let mut e = engine("report-by-exception", json!({"heartbeatIntervalMs":10}));
    let a = reading("a", "same", 0, 100.0);
    let b = reading("b", "same", 0, -100.0);
    assert_eq!(process(&mut e, &a, 0), reported(&a, "initial", 0, 0, true));
    assert_eq!(process(&mut e, &b, 5), reported(&b, "initial", 5, 5, true));
    assert_eq!(
        process(&mut e, &tick("a"), 10),
        reported(&a, "heartbeat", 10, 0, false)
    );
    pending(&process(&mut e, &tick("b"), 10));
    assert_eq!(
        process(&mut e, &tick("b"), 15),
        reported(&b, "heartbeat", 15, 5, false)
    );
}

#[test]
fn smoothing_default_alpha_preserves_metadata_and_unrounded_precision() {
    let mut e = engine("smooth-readings", json!({}));
    let values = [0.1, 0.2, -0.3, 1.0 / 3.0, 0.123456789012345];
    let mut previous = None;
    for (n, value) in values.into_iter().enumerate() {
        let mut input = reading("a", &format!("m{n}"), n as u64, value);
        input["metadata"] = json!({"nested":[{"quality":"good"}]});
        input["sampledAt"] = json!("1970-01-01T00:00:00Z");
        let expected = previous.map_or(value, |old| 0.5 * value + 0.5 * old);
        assert_eq!(
            process(&mut e, &input, n as u64),
            derived(
                &input,
                json!({"kind":"smoothed","smoothedValue":expected,"emittedAtMs":n})
            )
        );
        previous = Some(expected);
    }
    pending(&process(&mut e, &tick("a"), 100_000_000));
}

#[test]
fn smoothing_alpha_one_tiny_alpha_and_asset_isolation() {
    for alpha in [1.0, f64::MIN_POSITIVE, 0.25] {
        let mut e = engine("smooth-readings", json!({"alpha":alpha}));
        let a = reading("a", "same", 0, 8.0);
        let b = reading("b", "same", 0, -100.0);
        assert_eq!(process(&mut e, &a, 0)["smoothedValue"], 8.0);
        assert_eq!(process(&mut e, &b, 0)["smoothedValue"], -100.0);
        let next = reading("a", "next", 1, 4.0);
        assert_eq!(
            process(&mut e, &next, 1)["smoothedValue"],
            json!(alpha * 4.0 + (1.0 - alpha) * 8.0)
        );
        diagnostic(&process(&mut e, &next, 2), "duplicate");
    }
}

#[test]
fn smoothing_extreme_finite_inputs_do_not_overflow_via_subtractive_reformulation() {
    let mut e = engine("smooth-readings", json!({"alpha":0.5}));
    let first = reading("a", "one", 0, f64::MAX);
    assert_eq!(process(&mut e, &first, 0)["smoothedValue"], json!(f64::MAX));
    let opposite = reading("a", "two", 1, -f64::MAX);
    assert_eq!(process(&mut e, &opposite, 1)["smoothedValue"], 0.0);
    let third = reading("a", "three", 2, f64::MAX);
    assert_eq!(
        process(&mut e, &third, 2)["smoothedValue"],
        json!(0.5 * f64::MAX)
    );
}

#[test]
fn smoothing_nonfinite_input_errors_leave_output_history_and_watermark_unchanged() {
    let mut e = engine("smooth-readings", json!({"alpha":0.25}));
    process(&mut e, &reading("a", "one", 0, 8.0), 0);
    for literal in ["1e400", "-1e400", "NaN", "Infinity"] {
        let text = format!(
            r#"{{"kind":"reading","assetId":"a","messageId":"two","sequence":1,"value":{literal}}}"#
        );
        assert!(e.process(text.as_bytes(), 1).is_err());
    }
    let corrected = reading("a", "two", 1, 4.0);
    assert_eq!(process(&mut e, &corrected, 2)["smoothedValue"], 7.0);
    diagnostic(&process(&mut e, &corrected, 3), "duplicate");
}

#[test]
fn alarm_defaults_transition_at_inclusive_thresholds_without_repeats() {
    let mut e = engine("stable-alarm", json!({}));
    let cases = [
        (0, 79.0, None),
        (1, 80.0, Some(("active", 80.0))),
        (2, 90.0, None),
        (3, 75.0, None),
        (4, 70.0, Some(("cleared", 70.0))),
        (5, 60.0, None),
        (6, 75.0, None),
        (7, 80.0, Some(("active", 80.0))),
    ];
    for (sequence, value, transition) in cases {
        let input = derived(
            &reading("a", &format!("m{sequence}"), sequence, value),
            json!({"quality":{"source":"plc"}}),
        );
        let output = process(&mut e, &input, sequence);
        if let Some((state, threshold)) = transition {
            assert_eq!(
                output,
                alarm(&input, state, threshold, sequence, sequence, true)
            );
        } else {
            pending(&output);
        }
    }
    pending(&process(&mut e, &tick("a"), 8));
}

#[test]
fn alarm_readings_complete_pending_raise_and_clear_at_exact_duration() {
    let mut e = engine(
        "stable-alarm",
        json!({"raiseForMs":100,"clearForMs":50,"maxObservationGapMs":100}),
    );
    let cases = [
        (0, 80.0, 0, None),
        (1, 90.0, 99, None),
        (2, 81.0, 100, Some(("active", 80.0))),
        (3, 70.0, 110, None),
        (4, 60.0, 159, None),
        (5, 69.0, 160, Some(("cleared", 70.0))),
    ];
    for (seq, value, now, transition) in cases {
        let input = reading("a", &format!("m{seq}"), seq, value);
        let output = process(&mut e, &input, now);
        if let Some((state, threshold)) = transition {
            assert_eq!(output, alarm(&input, state, threshold, now, now, true));
        } else {
            pending(&output);
        }
    }
}

#[test]
fn alarm_ticks_complete_pending_with_last_reading_metadata_and_processing_ages() {
    let mut e = engine(
        "stable-alarm",
        json!({"raiseForMs":100,"clearForMs":50,"maxObservationGapMs":100}),
    );
    let high = derived(
        &reading("a", "high", 0, 80.0),
        json!({"sampledAt":"1970-01-01T00:00:20Z","custom":[1,2]}),
    );
    pending(&process(&mut e, &high, 1000));
    pending(&process(&mut e, &tick("a"), 1099));
    assert_eq!(
        process(&mut e, &tick("a"), 1100),
        alarm(&high, "active", 80.0, 1100, 1000, false)
    );
    pending(&process(&mut e, &tick("a"), 1100));
    let low = reading("a", "low", 1, 70.0);
    pending(&process(&mut e, &low, 1101));
    pending(&process(&mut e, &tick("a"), 1150));
    assert_eq!(
        process(&mut e, &tick("a"), 1151),
        alarm(&low, "cleared", 70.0, 1151, 1101, false)
    );
    pending(&process(&mut e, &tick("a"), 1152));
}

#[test]
fn alarm_middle_band_interrupts_both_raise_and_clear_candidates() {
    let mut e = engine(
        "stable-alarm",
        json!({"raiseForMs":10,"clearForMs":10,"maxObservationGapMs":100}),
    );
    for (seq, value, now) in [(0, 80.0, 0), (1, 75.0, 9), (2, 80.0, 10)] {
        pending(&process(
            &mut e,
            &reading("a", &format!("m{seq}"), seq, value),
            now,
        ));
    }
    pending(&process(&mut e, &tick("a"), 19));
    assert_eq!(process(&mut e, &tick("a"), 20)["state"], "active");
    for (seq, value, now) in [(3, 70.0, 21), (4, 75.0, 30), (5, 70.0, 31)] {
        pending(&process(
            &mut e,
            &reading("a", &format!("m{seq}"), seq, value),
            now,
        ));
    }
    pending(&process(&mut e, &tick("a"), 40));
    assert_eq!(process(&mut e, &tick("a"), 41)["state"], "cleared");
}

#[test]
fn alarm_gaps_reset_candidates_on_ticks_and_readings_but_not_active_state() {
    for reset_with_tick in [false, true] {
        let mut e = engine(
            "stable-alarm",
            json!({"raiseForMs":10,"clearForMs":10,"maxObservationGapMs":10}),
        );
        pending(&process(&mut e, &reading("a", "one", 0, 80.0), 0));
        if reset_with_tick {
            pending(&process(&mut e, &tick("a"), 11));
        }
        let high = reading("a", "two", 1, 80.0);
        pending(&process(&mut e, &high, 11));
        pending(&process(&mut e, &tick("a"), 20));
        assert_eq!(
            process(&mut e, &tick("a"), 21),
            alarm(&high, "active", 80.0, 21, 11, false)
        );
        let low = reading("a", "three", 2, 70.0);
        pending(&process(&mut e, &low, 22));
        if reset_with_tick {
            pending(&process(&mut e, &tick("a"), 33));
        }
        let low_again = reading("a", "four", 3, 70.0);
        pending(&process(&mut e, &low_again, 33));
        assert_eq!(
            process(&mut e, &tick("a"), 43),
            alarm(&low_again, "cleared", 70.0, 43, 33, false)
        );
    }
}

#[test]
fn alarm_default_gap_is_5000_and_durations_use_preceding_observation_not_candidate_age() {
    let mut e = engine("stable-alarm", json!({"raiseForMs":10000}));
    pending(&process(&mut e, &reading("a", "one", 0, 80.0), 0));
    pending(&process(&mut e, &reading("a", "two", 1, 81.0), 5000));
    let latest = reading("a", "three", 2, 82.0);
    assert_eq!(
        process(&mut e, &latest, 10000),
        alarm(&latest, "active", 80.0, 10000, 10000, true)
    );
    let mut e = engine("stable-alarm", json!({"raiseForMs":10000}));
    pending(&process(&mut e, &reading("a", "one", 0, 80.0), 0));
    pending(&process(&mut e, &tick("a"), 5001));
    pending(&process(&mut e, &tick("a"), 10000));
}

#[test]
fn alarm_rejects_do_not_refresh_observations_or_interrupt_candidates() {
    let mut e = engine(
        "stable-alarm",
        json!({"raiseForMs":10,"maxObservationGapMs":10,"maxHistoryPerAsset":1}),
    );
    let high = reading("a", "one", 1, 80.0);
    pending(&process(&mut e, &high, 0));
    diagnostic(&process(&mut e, &high, 8), "duplicate");
    diagnostic(
        &process(&mut e, &derived(&high, json!({"value":0})), 8),
        "conflict",
    );
    diagnostic(
        &process(&mut e, &reading("a", "stale", 0, 0.0), 8),
        "staleReading",
    );
    diagnostic(
        &process(&mut e, &reading("a", "stale-again", 1, 0.0), 9),
        "staleReading",
    );
    assert_eq!(
        process(&mut e, &tick("a"), 10),
        alarm(&high, "active", 80.0, 10, 0, false)
    );
    let mut e = engine(
        "stable-alarm",
        json!({"raiseForMs":11,"maxObservationGapMs":10}),
    );
    pending(&process(&mut e, &high, 0));
    diagnostic(&process(&mut e, &high, 10), "duplicate");
    pending(&process(&mut e, &tick("a"), 11));
}

#[test]
fn alarm_candidates_and_active_states_are_asset_local() {
    let mut e = engine("stable-alarm", json!({"raiseForMs":10}));
    let a = reading("a", "same", 0, 80.0);
    let b = reading("b", "same", 0, 80.0);
    pending(&process(&mut e, &a, 0));
    pending(&process(&mut e, &b, 5));
    assert_eq!(process(&mut e, &tick("a"), 10)["state"], "active");
    pending(&process(&mut e, &tick("b"), 10));
    assert_eq!(process(&mut e, &tick("b"), 15)["state"], "active");
    assert_eq!(
        process(&mut e, &reading("a", "clear", 1, 70.0), 16)["state"],
        "cleared"
    );
    pending(&process(&mut e, &reading("b", "still-active", 1, 75.0), 16));
}

#[test]
fn offline_registration_is_idempotent_and_times_out_at_exact_boundary() {
    let mut e = engine("offline-detection", json!({"timeoutMs":100}));
    let register = json!({"kind":"register","assetId":"a"});
    pending(&process(&mut e, &register, 1000));
    pending(&process(&mut e, &register, 1090));
    pending(&process(&mut e, &tick("a"), 1099));
    assert_eq!(
        process(&mut e, &tick("a"), 1100),
        availability("a", "offline", "timeout", 1100, None, 100)
    );
    pending(&process(&mut e, &tick("a"), 1200));
    pending(&process(&mut e, &register, 1200));
    pending(&process(&mut e, &tick("a"), 1300));
    assert_eq!(
        process(&mut e, &reading("a", "first", 0, 1.0), 1350),
        availability("a", "online", "recovered", 1350, Some(1350), 350)
    );
}

#[test]
fn offline_first_reading_online_updates_and_default_timeout_use_processing_clock() {
    let mut e = engine("offline-detection", json!({}));
    let first = derived(
        &reading("a", "one", 0, 1.0),
        json!({"sampledAt":"1970-01-01T00:00:20Z"}),
    );
    assert_eq!(
        process(&mut e, &first, 1000),
        availability("a", "online", "firstReading", 1000, Some(1000), 0)
    );
    pending(&process(&mut e, &reading("a", "two", 1, 2.0), 2000));
    pending(&process(&mut e, &tick("a"), 11999));
    assert_eq!(
        process(&mut e, &tick("a"), 12000),
        availability("a", "offline", "timeout", 12000, Some(2000), 10000)
    );
    pending(&process(&mut e, &tick("a"), 12001));
    assert_eq!(
        process(&mut e, &reading("a", "three", 2, 3.0), 12500),
        availability("a", "online", "recovered", 12500, Some(12500), 10500)
    );
}

#[test]
fn offline_late_reading_without_tick_emits_ordered_offline_recovery_batch() {
    for elapsed in [100, 101] {
        let mut e = engine("offline-detection", json!({"timeoutMs":100}));
        process(&mut e, &reading("a", "one", 0, 1.0), 1000);
        let late = reading("a", "two", 1, 2.0);
        let now = 1000 + elapsed;
        assert_eq!(
            process(&mut e, &late, now),
            json!({
                "kind":"batch",
                "records":[
                    availability("a","offline","timeout",now,Some(1000),elapsed),
                    availability("a","online","recovered",now,Some(now),elapsed)
                ]
            })
        );
        diagnostic(&process(&mut e, &late, now + 1), "duplicate");
        pending(&process(&mut e, &tick("a"), now + 99));
    }
}

#[test]
fn offline_late_first_measurement_uses_registration_age_for_recovery() {
    let mut e = engine("offline-detection", json!({"timeoutMs":100}));
    pending(&process(
        &mut e,
        &json!({"kind":"register","assetId":"a"}),
        10,
    ));
    assert_eq!(
        process(&mut e, &reading("a", "one", 0, 1.0), 110),
        json!({
            "kind":"batch",
            "records":[
                availability("a","offline","timeout",110,None,100),
                availability("a","online","recovered",110,Some(110),100)
            ]
        })
    );
}

#[test]
fn offline_reading_before_registration_timeout_is_first_reading() {
    let mut e = engine("offline-detection", json!({"timeoutMs":100}));
    pending(&process(
        &mut e,
        &json!({"kind":"register","assetId":"a"}),
        10,
    ));
    assert_eq!(
        process(&mut e, &reading("a", "one", 0, 1.0), 109),
        availability("a", "online", "firstReading", 109, Some(109), 0)
    );
    pending(&process(
        &mut e,
        &json!({"kind":"register","assetId":"a"}),
        150,
    ));
    assert_eq!(
        process(&mut e, &tick("a"), 209),
        availability("a", "offline", "timeout", 209, Some(109), 100)
    );
}

#[test]
fn offline_rejects_do_not_refresh_watch_or_trigger_implicit_offline_transition() {
    let mut e = engine(
        "offline-detection",
        json!({"timeoutMs":100,"maxHistoryPerAsset":1}),
    );
    let first = reading("a", "one", 1, 1.0);
    process(&mut e, &first, 0);
    diagnostic(&process(&mut e, &first, 100), "duplicate");
    diagnostic(
        &process(&mut e, &derived(&first, json!({"value":2})), 101),
        "conflict",
    );
    diagnostic(
        &process(&mut e, &reading("a", "stale", 0, 1.0), 102),
        "staleReading",
    );
    diagnostic(
        &process(&mut e, &reading("a", "stale-again", 1, 1.0), 103),
        "staleReading",
    );
    assert_eq!(
        process(&mut e, &tick("a"), 104),
        availability("a", "offline", "timeout", 104, Some(0), 104)
    );
    pending(&process(&mut e, &tick("a"), 105));
}

#[test]
fn offline_registration_capacity_and_asset_watches_are_independent() {
    let mut e = engine("offline-detection", json!({"maxAssets":2,"timeoutMs":10}));
    pending(&process(
        &mut e,
        &json!({"kind":"register","assetId":"a"}),
        0,
    ));
    pending(&process(
        &mut e,
        &json!({"kind":"register","assetId":"b"}),
        5,
    ));
    capacity(&process(
        &mut e,
        &json!({"kind":"register","assetId":"c"}),
        6,
    ));
    pending(&process(&mut e, &tick("c"), 10));
    assert_eq!(
        process(&mut e, &tick("a"), 10),
        availability("a", "offline", "timeout", 10, None, 10)
    );
    pending(&process(&mut e, &tick("b"), 10));
    assert_eq!(
        process(&mut e, &tick("b"), 15),
        availability("b", "offline", "timeout", 15, None, 10)
    );
}

#[test]
fn running_total_requires_explicit_seed_and_epoch_without_allocating_unknown_assets() {
    let mut e = engine("running-total", json!({"maxAssets":1,"initialStates":[]}));
    let input = role_reading("running-total", "a", "one", 1, 1.0);
    diagnostic(&process(&mut e, &input, 0), "uninitializedAsset");
    diagnostic(&process(&mut e, &reset("r", 1, 0), 1), "uninitializedAsset");
    pending(&process(&mut e, &tick("a"), 2));
    diagnostic(&process(&mut e, &input, 3), "uninitializedAsset");
    let mut e = engine("running-total", json!({}));
    rejects(&mut e, &reading("a", "one", 1, 1.0), 0);
    for epoch in [json!(-1), json!(0.5), json!("0"), json!(null)] {
        rejects(&mut e, &derived(&input, json!({"epoch":epoch})), 0);
    }
    assert_eq!(process(&mut e, &input, 0)["total"], 1.0);
}

#[test]
fn running_total_adds_signed_values_and_preserves_input_metadata() {
    let mut e = engine("running-total", json!({}));
    let mut total = 0.0;
    for (n, value) in [0.1, 0.2, -0.4, 0.0, 1.0 / 3.0].into_iter().enumerate() {
        let sequence = n as u64 + 1;
        let input = derived(
            &role_reading("running-total", "a", &format!("m{n}"), sequence, value),
            json!({"metadata":{"units":"kWh"},"sampledAt":"1970-01-01T00:00:00Z"}),
        );
        total += value;
        assert_eq!(
            process(&mut e, &input, sequence),
            derived(
                &input,
                json!({
                    "kind":"total","total":total,"stateVersion":sequence,
                    "epoch":0,"lastSequence":sequence,"emittedAtMs":sequence,
                    "lastSampledAt":"1970-01-01T00:00:00Z"
                })
            )
        );
    }
}

#[test]
fn running_total_reset_advances_epoch_version_and_sequence_and_retains_ids() {
    let mut e = engine("running-total", json!({}));
    let first = role_reading("running-total", "a", "one", 1, 5.0);
    process(&mut e, &first, 1);
    let r = derived(&reset("reset-one", 2, 1), json!({"operator":{"line":3}}));
    assert_eq!(
        process(&mut e, &r, 2),
        derived(
            &r,
            json!({
                "kind":"totalReset","total":0.0,"epoch":1,"stateVersion":2,
                "lastSequence":2,"emittedAtMs":2
            })
        )
    );
    diagnostic(&process(&mut e, &r, 3), "duplicateReset");
    diagnostic(
        &process(&mut e, &derived(&r, json!({"operator":{"line":4}})), 3),
        "conflictReset",
    );
    diagnostic(&process(&mut e, &first, 3), "duplicate");
    diagnostic(
        &process(&mut e, &derived(&first, json!({"value":99})), 3),
        "conflict",
    );
    let old_epoch = role_reading("running-total", "a", "old-epoch", 100, 100.0);
    diagnostic(&process(&mut e, &old_epoch, 4), "epochConflict");
    let current = derived(
        &role_reading("running-total", "a", "two", 3, 7.0),
        json!({"epoch":1}),
    );
    let output = process(&mut e, &current, 5);
    assert_eq!(output["total"], 7.0);
    assert_eq!(output["stateVersion"], 3);
    assert_eq!(output["epoch"], 1);
    assert_eq!(output["lastSequence"], 3);
    diagnostic(&process(&mut e, &r, 6), "duplicateReset");
}

#[test]
fn running_total_reset_conflicts_versions_and_stale_sequences_are_atomic() {
    let mut e = engine("running-total", json!({}));
    process(
        &mut e,
        &role_reading("running-total", "a", "one", 1, 5.0),
        0,
    );
    diagnostic(&process(&mut e, &reset("r", 2, 0), 1), "versionConflict");
    diagnostic(&process(&mut e, &reset("r", 1, 1), 2), "staleReading");
    diagnostic(&process(&mut e, &reset("r", 0, 1), 3), "staleReading");
    let r = reset("r", 2, 1);
    assert_eq!(process(&mut e, &r, 4)["stateVersion"], 2);
    for changed in [
        derived(&r, json!({"sequence":3})),
        derived(&r, json!({"expectedStateVersion":2})),
        derived(&r, json!({"metadata":"different"})),
    ] {
        diagnostic(&process(&mut e, &changed, 5), "conflictReset");
    }
    diagnostic(&process(&mut e, &r, 6), "duplicateReset");
    let next = reset("next", 3, 2);
    let output = process(&mut e, &next, 7);
    assert_eq!(output["epoch"], 2);
    assert_eq!(output["stateVersion"], 3);
    assert_eq!(output["lastSequence"], 3);
}

#[test]
fn running_total_epoch_conflicts_do_not_consume_id_sequence_or_total() {
    let mut e = engine("running-total", json!({}));
    let valid = role_reading("running-total", "a", "one", 1, 5.0);
    for epoch in [1, u64::MAX] {
        diagnostic(
            &process(&mut e, &derived(&valid, json!({"epoch":epoch})), 0),
            "epochConflict",
        );
    }
    let output = process(&mut e, &valid, 1);
    assert_eq!(output["total"], 5.0);
    assert_eq!(output["stateVersion"], 1);
    diagnostic(
        &process(&mut e, &reset("bad", 2, 100), 2),
        "versionConflict",
    );
    let next = role_reading("running-total", "a", "two", 2, 6.0);
    assert_eq!(process(&mut e, &next, 3)["total"], 11.0);
}

#[test]
fn running_total_reset_schema_errors_do_not_reserve_reset_ids() {
    for (field, invalid) in [
        ("resetId", json!([null, "", 7])),
        ("sequence", json!([null, -1, 1.5, "1"])),
        ("expectedStateVersion", json!([null, -1, 0.5, "0"])),
    ] {
        for value in invalid.as_array().unwrap() {
            let mut e = engine("running-total", json!({}));
            let valid = reset("r", 1, 0);
            let mut invalid = valid.clone();
            invalid[field] = value.clone();
            rejects(&mut e, &invalid, 0);
            assert_eq!(process(&mut e, &valid, 0)["kind"], "totalReset");
        }
        let mut e = engine("running-total", json!({}));
        let mut missing = reset("r", 1, 0);
        missing.as_object_mut().unwrap().remove(field);
        rejects(&mut e, &missing, 0);
    }
    for field in [
        "total",
        "epoch",
        "stateVersion",
        "lastSequence",
        "emittedAtMs",
    ] {
        let mut e = engine("running-total", json!({}));
        let mut invalid = reset("r", 1, 0);
        invalid[field] = json!(0);
        rejects(&mut e, &invalid, 0);
        assert_eq!(process(&mut e, &reset("r", 1, 0), 0)["epoch"], 1);
    }
}

#[test]
fn running_total_checkpoint_restart_restores_state_but_not_retry_history() {
    let mut e = engine("running-total", json!({}));
    let first = role_reading("running-total", "a", "one", 1, 5.0);
    process(&mut e, &first, 1);
    let r = reset("r", 2, 1);
    process(&mut e, &r, 2);
    let current = derived(
        &role_reading("running-total", "a", "two", 3, 7.0),
        json!({"epoch":1}),
    );
    let checkpoint = process(&mut e, &current, 3);
    let state = json!({
        "assetId":"a","total":checkpoint["total"],
        "epoch":checkpoint["epoch"],"stateVersion":checkpoint["stateVersion"],
        "lastSequence":checkpoint["lastSequence"]
    });
    let mut restarted = engine("running-total", json!({"initialStates":[state]}));
    diagnostic(&process(&mut restarted, &current, 4), "staleReading");
    diagnostic(
        &process(&mut restarted, &reset("r", 2, 3), 4),
        "staleReading",
    );
    let next = derived(
        &role_reading("running-total", "a", "three", 4, 2.0),
        json!({"epoch":1}),
    );
    let output = process(&mut restarted, &next, 5);
    assert_eq!(output["total"], 9.0);
    assert_eq!(output["stateVersion"], 4);
    assert_eq!(output["epoch"], 1);
    diagnostic(
        &process(
            &mut restarted,
            &role_reading("running-total", "a", "old", 100, 1000.0),
            6,
        ),
        "epochConflict",
    );
}

#[test]
fn running_total_reading_sum_overflow_is_error_and_atomic() {
    let mut e = engine(
        "running-total",
        json!({"initialStates":[seed("a",f64::MAX,7,2,9)]}),
    );
    let overflow = derived(
        &reading("a", "same", 10, f64::MAX),
        json!({"epoch":2,"sampledAt":"1970-01-01T00:00:01Z"}),
    );
    rejects(&mut e, &overflow, 1000);
    rejects(&mut e, &overflow, 1001);
    let corrected = derived(
        &reading("a", "same", 10, -f64::MAX),
        json!({"epoch":2,"sampledAt":"1970-01-01T00:00:00Z"}),
    );
    assert_eq!(
        process(&mut e, &corrected, 1002),
        derived(
            &corrected,
            json!({
                "kind":"total","total":0.0,"epoch":2,"stateVersion":8,
                "lastSequence":10,"emittedAtMs":1002,
                "lastSampledAt":"1970-01-01T00:00:00Z"
            })
        )
    );
}

#[test]
fn running_total_version_overflow_errors_without_reserving_reading_ids() {
    let mut e = engine(
        "running-total",
        json!({"initialStates":[seed("a",5.0,u64::MAX,0,0)]}),
    );
    let input = role_reading("running-total", "a", "one", 1, 1.0);
    rejects(&mut e, &input, 0);
    rejects(&mut e, &input, 1);
    rejects(&mut e, &derived(&input, json!({"value":2})), 2);
    diagnostic(
        &process(
            &mut e,
            &role_reading("running-total", "a", "stale", 0, 1.0),
            3,
        ),
        "staleReading",
    );
    rejects(&mut e, &reset("r", 1, u64::MAX), 4);
    rejects(&mut e, &reset("r", 1, u64::MAX), 5);
}

#[test]
fn running_total_reset_epoch_and_version_overflow_are_atomic() {
    for (version, epoch) in [(7, u64::MAX), (u64::MAX, 7)] {
        let mut e = engine(
            "running-total",
            json!({"initialStates":[seed("a",5.0,version,epoch,0)]}),
        );
        let r = reset("r", 1, version);
        rejects(&mut e, &r, 0);
        rejects(&mut e, &r, 1);
        rejects(
            &mut e,
            &derived(&r, json!({"metadata":"not-a-conflict"})),
            2,
        );
        if version != u64::MAX {
            let input = derived(&reading("a", "one", 1, 2.0), json!({"epoch":epoch}));
            let output = process(&mut e, &input, 3);
            assert_eq!(output["total"], 7.0);
            assert_eq!(output["stateVersion"], version + 1);
            assert_eq!(output["epoch"], epoch);
        }
    }
}

#[test]
fn running_total_reset_history_evicts_oldest_but_keeps_version_and_sequence_gates() {
    let mut e = engine("running-total", json!({"maxUpdatesPerAsset":1}));
    let first = reset("one", 1, 0);
    process(&mut e, &first, 0);
    let second = reset("two", 100, 1);
    assert_eq!(process(&mut e, &second, 1)["stateVersion"], 2);
    diagnostic(&process(&mut e, &second, 2), "duplicateReset");
    diagnostic(&process(&mut e, &first, 3), "versionConflict");
    diagnostic(&process(&mut e, &reset("one", 1, 2), 3), "staleReading");
    let input = derived(&reading("a", "reading", 101, 5.0), json!({"epoch":2}));
    let output = process(&mut e, &input, 4);
    assert_eq!(output["total"], 5.0);
    assert_eq!(output["stateVersion"], 3);
    assert_eq!(output["epoch"], 2);
    process(&mut e, &tick("a"), 100_000_000);
    diagnostic(&process(&mut e, &second, 100_000_001), "duplicateReset");
    assert_eq!(
        process(&mut e, &reset("three", 102, 3), 100_000_002)["stateVersion"],
        4
    );
}

#[test]
fn running_total_default_reset_lookback_is_512_and_streams_over_ten_times_capacity() {
    let mut e = engine("running-total", json!({}));
    for n in 1..=5121 {
        let r = reset(&format!("r{n}"), n, n - 1);
        let output = process(&mut e, &r, n);
        assert_eq!(output["kind"], "totalReset");
        assert_eq!(output["epoch"], n);
        assert_eq!(output["stateVersion"], n);
    }
    diagnostic(
        &process(&mut e, &reset("r4610", 4610, 4609), 5122),
        "duplicateReset",
    );
    diagnostic(
        &process(&mut e, &reset("r4609", 4609, 4608), 5123),
        "versionConflict",
    );
    diagnostic(
        &process(&mut e, &reset("r1", 1, 5121), 5124),
        "staleReading",
    );
    diagnostic(
        &process(&mut e, &reset("r5121", 5122, 5121), 5125),
        "conflictReset",
    );
    pending(&process(&mut e, &tick("a"), 100_000_000));
    diagnostic(
        &process(&mut e, &reset("r4610", 4610, 4609), 100_000_001),
        "duplicateReset",
    );
    assert_eq!(
        process(&mut e, &reset("next", 5122, 5121), 100_000_002)["stateVersion"],
        5122
    );
}

#[test]
fn running_total_reading_and_reset_capacities_are_separate() {
    let mut e = engine(
        "running-total",
        json!({"maxHistoryPerAsset":1,"maxUpdatesPerAsset":1}),
    );
    let first = role_reading("running-total", "a", "one", 1, 5.0);
    process(&mut e, &first, 0);
    assert_eq!(process(&mut e, &reset("r", 2, 1), 1)["epoch"], 1);
    let next = derived(&reading("a", "two", 3, 7.0), json!({"epoch":1}));
    assert_eq!(process(&mut e, &next, 2)["total"], 7.0);
    diagnostic(&process(&mut e, &first, 3), "staleReading");
    diagnostic(&process(&mut e, &reset("r", 2, 1), 4), "duplicateReset");
}

#[test]
fn running_total_assets_isolate_epochs_versions_totals_and_ids() {
    let mut e = engine("running-total", json!({}));
    let a = role_reading("running-total", "a", "same", 1, 5.0);
    let b = role_reading("running-total", "b", "same", 1, 10.0);
    assert_eq!(process(&mut e, &a, 0)["total"], 5.0);
    assert_eq!(process(&mut e, &b, 0)["total"], 10.0);
    process(&mut e, &reset("same-reset", 2, 1), 1);
    let next_b = role_reading("running-total", "b", "next", 2, 2.0);
    let output = process(&mut e, &next_b, 2);
    assert_eq!(output["total"], 12.0);
    assert_eq!(output["epoch"], 0);
    assert_eq!(output["stateVersion"], 2);
    let b_reset = derived(&reset("same-reset", 3, 2), json!({"assetId":"b"}));
    assert_eq!(process(&mut e, &b_reset, 3)["epoch"], 1);
}

#[test]
fn running_total_seed_schema_and_capacity_are_validated() {
    for invalid in [
        json!({"assetId":"a","total":0,"stateVersion":0,"epoch":0}),
        json!({"assetId":"a","total":"0","stateVersion":0,"epoch":0,"lastSequence":0}),
        json!({"assetId":"a","total":0,"stateVersion":-1,"epoch":0,"lastSequence":0}),
        json!({"assetId":"a","total":0,"stateVersion":0,"epoch":-1,"lastSequence":0}),
        json!({"assetId":"a","total":0,"stateVersion":0,"epoch":0,"lastSequence":-1}),
        json!({"assetId":"","total":0,"stateVersion":0,"epoch":0,"lastSequence":0}),
    ] {
        let config = configuration("running-total", json!({"initialStates":[invalid]}));
        assert!(Config::parse(&config.to_string()).is_err(), "{config}");
    }
    for states in [
        json!([seed("a", 0.0, 0, 0, 0), seed("a", 1.0, 1, 1, 1)]),
        json!([seed("a", 0.0, 0, 0, 0), seed("b", 0.0, 0, 0, 0)]),
    ] {
        let config = configuration(
            "running-total",
            json!({"maxAssets":1,"initialStates":states}),
        );
        assert!(Config::parse(&config.to_string()).is_err(), "{config}");
    }
    let text = r#"{"role":"running-total","initialStates":[{"assetId":"a","total":1e400,"stateVersion":0,"epoch":0,"lastSequence":0}]}"#;
    assert!(Config::parse(text).is_err());
}

#[test]
fn rejected_timestamp_payloads_do_not_refresh_or_change_time_driven_roles() {
    for role in ["report-by-exception", "stable-alarm", "offline-detection"] {
        let options = match role {
            "report-by-exception" => json!({"heartbeatIntervalMs":10}),
            "stable-alarm" => json!({"raiseForMs":10,"maxObservationGapMs":10}),
            "offline-detection" => json!({"timeoutMs":10}),
            _ => unreachable!(),
        };
        let mut e = engine(role, options);
        let first = derived(
            &reading("a", "one", 0, 80.0),
            json!({"sampledAt":"1970-01-01T00:00:00.100Z"}),
        );
        process(&mut e, &first, 100);
        let bad = derived(
            &reading("a", "two", 1, 0.0),
            json!({"sampledAt":"1970-01-01T00:00:00.099Z"}),
        );
        diagnostic(&process(&mut e, &bad, 109), "staleReading");
        let output = process(&mut e, &tick("a"), 110);
        match role {
            "report-by-exception" => {
                assert_eq!(output, reported(&first, "heartbeat", 110, 100, false))
            }
            "stable-alarm" => {
                assert_eq!(output, alarm(&first, "active", 80.0, 110, 100, false))
            }
            "offline-detection" => {
                assert_eq!(
                    output,
                    availability("a", "offline", "timeout", 110, Some(100), 10)
                )
            }
            _ => unreachable!(),
        }
    }
}

#[test]
fn timestamp_watermarks_are_asset_local_and_equal_timestamps_are_allowed() {
    for role in ROLES {
        let mut e = engine(role, json!({}));
        let a = derived(
            &role_reading(role, "a", "same", 1, 1.0),
            json!({"sampledAt":"1970-01-01T00:00:01Z"}),
        );
        let b = derived(
            &role_reading(role, "b", "same", 1, 2.0),
            json!({"sampledAt":"1970-01-01T00:00:00Z"}),
        );
        assert_ne!(process(&mut e, &a, 1000)["kind"], "diagnostic");
        assert_ne!(process(&mut e, &b, 1000)["kind"], "diagnostic");
        let next = derived(
            &role_reading(role, "b", "next", 2, 3.0),
            json!({"sampledAt":"1970-01-01T00:00:00Z"}),
        );
        assert_ne!(process(&mut e, &next, 1000)["kind"], "diagnostic");
    }
}

#[test]
fn ticks_validate_schema_without_allocating_or_consuming_measurement_history() {
    for role in ROLES {
        let mut e = engine(role, json!({"maxHistoryPerAsset":1}));
        for invalid in [
            json!({"kind":"tick"}),
            json!({"kind":"tick","assetId":null}),
            json!({"kind":"tick","assetId":""}),
            json!({"kind":"tick","assetId":12}),
            json!({"kind":"tick","assetId":"unknown","sampledAt":"not-a-time"}),
        ] {
            rejects(&mut e, &invalid, 1000);
        }
        let unknown_tick = derived(
            &tick("unknown"),
            json!({"sampledAt":"1970-01-01T00:00:01Z","metadata":{"source":"timer"}}),
        );
        pending(&process(&mut e, &unknown_tick, 1000));
        let input = role_reading(role, "a", "one", 1, 1.0);
        assert_ne!(process(&mut e, &input, 1000)["kind"], "diagnostic");
        for _ in 0..3 {
            process(&mut e, &tick("a"), 1000);
        }
        diagnostic(&process(&mut e, &input, 1000), "duplicate");
    }
}

#[test]
fn rejected_conflicts_do_not_advance_present_timestamp_watermarks() {
    for role in ROLES {
        let mut e = engine(role, json!({}));
        let first = derived(
            &role_reading(role, "a", "one", 1, 1.0),
            json!({"sampledAt":"1970-01-01T00:00:00Z"}),
        );
        process(&mut e, &first, 1000);
        let conflict = derived(&first, json!({"sampledAt":"1970-01-01T00:00:01Z"}));
        diagnostic(&process(&mut e, &conflict, 1000), "conflict");
        let next = derived(
            &role_reading(role, "a", "two", 2, 2.0),
            json!({"sampledAt":"1970-01-01T00:00:00Z"}),
        );
        assert_ne!(process(&mut e, &next, 1000)["kind"], "diagnostic");
    }
}

#[test]
fn alarm_opposite_threshold_observations_interrupt_candidates() {
    let mut e = engine(
        "stable-alarm",
        json!({"raiseForMs":10,"clearForMs":10,"maxObservationGapMs":100}),
    );
    for (seq, value, now) in [(0, 80.0, 0), (1, 60.0, 9), (2, 90.0, 10)] {
        pending(&process(
            &mut e,
            &reading("a", &format!("m{seq}"), seq, value),
            now,
        ));
    }
    pending(&process(&mut e, &tick("a"), 19));
    assert_eq!(process(&mut e, &tick("a"), 20)["state"], "active");
    for (seq, value, now) in [(3, 70.0, 21), (4, 90.0, 30), (5, 60.0, 31)] {
        pending(&process(
            &mut e,
            &reading("a", &format!("m{seq}"), seq, value),
            now,
        ));
    }
    pending(&process(&mut e, &tick("a"), 40));
    assert_eq!(process(&mut e, &tick("a"), 41)["state"], "cleared");
}

#[test]
fn offline_registration_schema_rejection_does_not_start_watch() {
    let mut e = engine("offline-detection", json!({"maxAssets":1,"timeoutMs":1}));
    for invalid in [
        json!({"kind":"register"}),
        json!({"kind":"register","assetId":""}),
        json!({"kind":"register","assetId":false}),
    ] {
        rejects(&mut e, &invalid, 0);
    }
    pending(&process(&mut e, &tick("a"), 10));
    pending(&process(
        &mut e,
        &json!({"kind":"register","assetId":"a"}),
        10,
    ));
    assert_eq!(
        process(&mut e, &tick("a"), 11),
        availability("a", "offline", "timeout", 11, None, 1)
    );
}

#[test]
fn running_total_reading_can_reach_maximum_version_before_next_update_errors() {
    let mut e = engine(
        "running-total",
        json!({"initialStates":[seed("a",0.0,u64::MAX-1,0,0)]}),
    );
    let first = role_reading("running-total", "a", "one", 1, 2.0);
    let output = process(&mut e, &first, 0);
    assert_eq!(output["stateVersion"], u64::MAX);
    assert_eq!(output["total"], 2.0);
    diagnostic(&process(&mut e, &first, 1), "duplicate");
    let next = role_reading("running-total", "a", "two", 2, 3.0);
    rejects(&mut e, &next, 2);
    rejects(&mut e, &next, 3);
    diagnostic(&process(&mut e, &first, 4), "duplicate");
}

#[test]
fn running_total_reset_can_reach_maximum_epoch_and_version_without_wrapping() {
    let mut e = engine(
        "running-total",
        json!({"initialStates":[seed("a",5.0,u64::MAX-1,u64::MAX-1,0)]}),
    );
    let r = reset("r", 1, u64::MAX - 1);
    let output = process(&mut e, &r, 0);
    assert_eq!(output["total"], 0.0);
    assert_eq!(output["stateVersion"], u64::MAX);
    assert_eq!(output["epoch"], u64::MAX);
    assert_eq!(output["lastSequence"], 1);
    diagnostic(&process(&mut e, &r, 1), "duplicateReset");
    rejects(&mut e, &reset("next", 2, u64::MAX), 2);
    diagnostic(&process(&mut e, &r, 3), "duplicateReset");
}

#[test]
fn running_total_reset_history_retains_ids_across_multiple_epochs() {
    let mut e = engine("running-total", json!({}));
    let first_reading = role_reading("running-total", "a", "reading", 1, 2.0);
    process(&mut e, &first_reading, 0);
    let first_reset = reset("first", 2, 1);
    process(&mut e, &first_reset, 1);
    process(&mut e, &reset("second", 3, 2), 2);
    diagnostic(&process(&mut e, &first_reset, 3), "duplicateReset");
    diagnostic(&process(&mut e, &first_reading, 4), "duplicate");
    diagnostic(
        &process(&mut e, &derived(&first_reset, json!({"sequence":4})), 5),
        "conflictReset",
    );
    let current = derived(&reading("a", "new", 4, 3.0), json!({"epoch":2}));
    let output = process(&mut e, &current, 6);
    assert_eq!(output["total"], 3.0);
    assert_eq!(output["stateVersion"], 4);
    assert_eq!(output["epoch"], 2);
}

#[test]
fn running_total_overflow_at_history_capacity_does_not_mutate_checkpoint_fields() {
    let mut e = engine("running-total", json!({"maxHistoryPerAsset":1}));
    let first = role_reading("running-total", "a", "one", 1, f64::MAX);
    process(&mut e, &first, 0);
    let rejected = role_reading("running-total", "a", "full", 100, f64::MAX);
    rejects(&mut e, &rejected, 1);
    diagnostic(&process(&mut e, &first, 1), "duplicate");
    let r = reset("r", 2, 1);
    let output = process(&mut e, &r, 2);
    assert_eq!(output["kind"], "totalReset");
    assert_eq!(output["epoch"], 1);
    assert_eq!(output["stateVersion"], 2);
    assert_eq!(output["lastSequence"], 2);
    diagnostic(&process(&mut e, &first, 3), "duplicate");
    let current = derived(&reading("a", "full", 3, 1.0), json!({"epoch":1}));
    let output = process(&mut e, &current, 4);
    assert_eq!(output["total"], 1.0);
    assert_eq!(output["stateVersion"], 3);
    assert_eq!(output["lastSequence"], 3);
    diagnostic(&process(&mut e, &first, 5), "staleReading");
}

#[test]
fn running_total_without_initial_states_does_not_implicitly_seed_assets() {
    let config = Config::parse(&json!({"role":"running-total"}).to_string()).unwrap();
    let mut e = Engine::new(config).unwrap();
    let input = role_reading("running-total", "a", "one", 1, 1.0);
    diagnostic(&process(&mut e, &input, 0), "uninitializedAsset");
    diagnostic(&process(&mut e, &reset("r", 1, 0), 1), "uninitializedAsset");
    pending(&process(&mut e, &tick("a"), 2));
}

#[test]
fn retry_does_not_refresh_fifo_retention_and_conflict_does_not_prune_history() {
    for role in ROLES {
        let mut e = engine(role, json!({"maxHistoryPerAsset":2}));
        // Deliberately reverse lexical ID order: eviction is acceptance order.
        let first = role_reading(role, "a", "z-first", 1, 1.0);
        let second = role_reading(role, "a", "a-second", 2, 2.0);
        process(&mut e, &first, 0);
        process(&mut e, &second, 1);
        diagnostic(&process(&mut e, &first, 2), "duplicate");
        diagnostic(
            &process(&mut e, &derived(&first, json!({"sequence":100})), 3),
            "conflict",
        );
        diagnostic(&process(&mut e, &second, 4), "duplicate");
        let third = role_reading(role, "a", "third", 3, 3.0);
        assert_ne!(process(&mut e, &third, 5)["kind"], "diagnostic");
        diagnostic(&process(&mut e, &first, 6), "staleReading");
        diagnostic(&process(&mut e, &second, 7), "duplicate");
    }
}

#[test]
fn evicted_id_reuse_with_new_sequence_is_outside_the_conflict_detection_contract() {
    for role in ROLES {
        let mut e = engine(role, json!({"maxHistoryPerAsset":1}));
        process(&mut e, &role_reading(role, "a", "old", 1, 1.0), 0);
        process(&mut e, &role_reading(role, "a", "new", 2, 2.0), 1);
        // Producer uniqueness is required: the core cannot prove this reuse
        // after eviction, although replaying its original sequence is safe.
        diagnostic(
            &process(&mut e, &role_reading(role, "a", "old", 1, 1.0), 2),
            "staleReading",
        );
        assert_ne!(
            process(&mut e, &role_reading(role, "a", "old", 3, 3.0), 3)["kind"],
            "diagnostic"
        );
    }
    let mut e = engine("running-total", json!({"maxUpdatesPerAsset":1}));
    process(&mut e, &reset("old", 1, 0), 0);
    process(&mut e, &reset("new", 2, 1), 1);
    diagnostic(&process(&mut e, &reset("old", 3, 0), 2), "versionConflict");
    assert_eq!(process(&mut e, &reset("old", 3, 2), 3)["epoch"], 3);
}

#[test]
fn reset_overflow_at_full_lookback_preserves_retained_payloads() {
    for (state_version, epoch) in [(u64::MAX - 1, 0), (0, u64::MAX - 1)] {
        let mut e = engine(
            "running-total",
            json!({
                "maxUpdatesPerAsset":1,
                "initialStates":[seed("a",5.0,state_version,epoch,0)]
            }),
        );
        let first = reset("first", 1, state_version);
        assert_eq!(
            process(&mut e, &first, 0)["stateVersion"],
            state_version + 1
        );
        rejects(&mut e, &reset("overflow", 2, state_version + 1), 1);
        diagnostic(&process(&mut e, &first, 2), "duplicateReset");
        diagnostic(
            &process(&mut e, &derived(&first, json!({"sequence":3})), 3),
            "conflictReset",
        );
    }
}
