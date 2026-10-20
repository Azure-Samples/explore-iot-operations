// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::common::{diagnostic, number, pack, string, timestamp, version, Config, Result};

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    piece: String,
    run: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Side {
    Prediction,
    Measurement,
}

impl Side {
    fn name(self) -> &'static str {
        match self {
            Self::Prediction => "prediction",
            Self::Measurement => "measurement",
        }
    }
}

struct Pending {
    side: Side,
    input: Value,
    since: u64,
}

struct Completed {
    prediction: Value,
    measurement: Value,
    since: u64,
}

#[derive(Default)]
struct Asset {
    pending: BTreeMap<Key, Pending>,
    completed: BTreeMap<Key, Completed>,
}

/// Bounded, volatile correlation and deduplication state.
pub struct Correlator {
    config: Config,
    assets: BTreeMap<String, Asset>,
}

impl Correlator {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            assets: BTreeMap::new(),
        }
    }

    pub fn process(&mut self, input: Value, now_ms: u64) -> Result<Value> {
        if !input.is_object() {
            return Err("payload must be a JSON object".into());
        }
        let kind = string(&input, "kind")?;
        let asset = string(&input, "assetId")?.to_owned();
        let side = match kind {
            "prediction" => Some(Side::Prediction),
            "measurement" => Some(Side::Measurement),
            "tick" => None,
            _ => return Err(format!("unsupported correlator kind: {kind}")),
        };
        let run = if input.get("runId").is_some() {
            Some(string(&input, "runId")?.to_owned())
        } else {
            None
        };
        for field in ["sampledAt", "predictedAt", "measuredAt"] {
            if input.get(field).is_some() {
                timestamp(string(&input, field)?)?;
            }
            for field in [
                "speed",
                "temperature",
                "speedCoefficient",
                "temperatureCoefficient",
                "intercept",
                "residual",
                "targetError",
            ] {
                if input.get(field).is_some() {
                    number(&input, field)?;
                }
            }
        }
        let Some(side) = side else {
            let mut records = Vec::new();
            self.expire(now_ms, &mut records);
            return Ok(pack(records));
        };
        let key = Key {
            piece: string(&input, "pieceId")?.to_owned(),
            run,
        };
        match side {
            Side::Prediction => {
                if version(&input, "modelVersion")? == 0 {
                    return Err("modelVersion must be positive".into());
                }
                number(&input, "predictedWeight")?;
            }
            Side::Measurement => {
                number(&input, "measuredWeight")?;
                number(&input, "targetWeight")?;
            }
        }

        // Validate a potential join before collecting expiry outputs: an Err must
        // not consume expiry diagnostics that the caller never receives.
        let merged = self
            .assets
            .get(&asset)
            .and_then(|a| a.pending.get(&key))
            .filter(|p| {
                p.side != side && now_ms.saturating_sub(p.since) < self.config.pending_ttl_ms
            })
            .map(|p| match side {
                Side::Prediction => merge(&input, &p.input),
                Side::Measurement => merge(&p.input, &input),
            })
            .transpose()?;

        let mut records = Vec::new();
        self.expire(now_ms, &mut records);
        if let Some(state) = self.assets.get_mut(&asset) {
            if let Some(done) = state.completed.get(&key) {
                let original = match side {
                    Side::Prediction => &done.prediction,
                    Side::Measurement => &done.measurement,
                };
                records.push(key_diagnostic(
                    if original == &input {
                        "duplicate"
                    } else {
                        "conflict"
                    },
                    &asset,
                    &key,
                    side,
                    "completed key already received this side",
                ));
                return Ok(pack(records));
            }
            if let Some(pending) = state.pending.get(&key) {
                if pending.side == side {
                    records.push(key_diagnostic(
                        if pending.input == input {
                            "duplicate"
                        } else {
                            "conflict"
                        },
                        &asset,
                        &key,
                        side,
                        "pending key already received this side",
                    ));
                } else if state.completed.len() >= self.config.max_completed_per_asset {
                    records.push(key_diagnostic(
                        "capacity",
                        &asset,
                        &key,
                        side,
                        "maxCompletedPerAsset reached; pending input retained",
                    ));
                } else {
                    let output = merged.expect("unexpired opposite side was validated");
                    let pending = state.pending.remove(&key).expect("pending key exists");
                    let (prediction, measurement) = match side {
                        Side::Prediction => (input, pending.input),
                        Side::Measurement => (pending.input, input),
                    };
                    state.completed.insert(
                        key,
                        Completed {
                            prediction,
                            measurement,
                            since: now_ms,
                        },
                    );
                    records.push(output);
                }
                return Ok(pack(records));
            }
            if state.pending.len() >= self.config.max_pending_per_asset {
                records.push(key_diagnostic(
                    "capacity",
                    &asset,
                    &key,
                    side,
                    "maxPendingPerAsset reached; no pending input evicted",
                ));
                return Ok(pack(records));
            }
        } else if self.assets.len() >= self.config.max_assets {
            records.push(key_diagnostic(
                "capacity",
                &asset,
                &key,
                side,
                "maxAssets reached; no asset evicted",
            ));
            return Ok(pack(records));
        }
        self.assets.entry(asset).or_default().pending.insert(
            key,
            Pending {
                side,
                input,
                since: now_ms,
            },
        );
        Ok(pack(records))
    }

    fn expire(&mut self, now_ms: u64, records: &mut Vec<Value>) {
        let pending_ttl = self.config.pending_ttl_ms;
        let completed_ttl = self.config.completed_ttl_ms;
        self.assets.retain(|asset, state| {
            state.pending.retain(|key, pending| {
                if now_ms.saturating_sub(pending.since) >= pending_ttl {
                    records.push(key_diagnostic(
                        "expired",
                        asset,
                        key,
                        pending.side,
                        "pending input exceeded processing-time retention",
                    ));
                    false
                } else {
                    true
                }
            });
            state
                .completed
                .retain(|_, done| now_ms.saturating_sub(done.since) < completed_ttl);
            !state.pending.is_empty() || !state.completed.is_empty()
        });
    }
}

fn key_diagnostic(code: &str, asset: &str, key: &Key, side: Side, detail: &str) -> Value {
    let mut output = diagnostic(code, asset, detail);
    output["pieceId"] = json!(key.piece);
    output["side"] = json!(side.name());
    if let Some(run) = &key.run {
        output["runId"] = json!(run);
    }
    output
}

fn merge(prediction: &Value, measurement: &Value) -> Result<Value> {
    let mut merged = prediction
        .as_object()
        .expect("validated prediction")
        .clone();
    merged.remove("kind");
    for (field, value) in measurement.as_object().expect("validated measurement") {
        if field == "kind" {
            continue;
        }
        if let Some(original) = merged.get(field) {
            if original != value {
                return Err(format!("correlation field conflict: {field}"));
            }
        } else {
            merged.insert(field.clone(), value.clone());
        }
    }
    let measured = number(measurement, "measuredWeight")?;
    let residual = measured - number(prediction, "predictedWeight")?;
    let target_error = measured - number(measurement, "targetWeight")?;
    if !residual.is_finite() || !target_error.is_finite() {
        return Err("correlation arithmetic overflow".into());
    }
    for (field, value) in [("residual", residual), ("targetError", target_error)] {
        if let Some(original) = merged.get(field) {
            let original = original
                .as_f64()
                .filter(|n| n.is_finite())
                .ok_or_else(|| format!("missing or non-finite numeric {field}"))?;
            if original != value {
                return Err(format!("correlation field conflict: {field}"));
            }
        } else {
            merged.insert(field.into(), json!(value));
        }
    }
    merged.insert("kind".into(), json!("correlated"));
    Ok(Value::Object(merged))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> Config {
        Config::parse(
            r#"{"role":"correlate-by-id","maxAssets":2,"maxPendingPerAsset":2,
            "maxCompletedPerAsset":2,"pendingTtlMs":10,"completedTtlMs":20,
            "allowedLatenessMs":0}"#,
        )
        .unwrap()
    }

    fn prediction(piece: &str) -> Value {
        json!({"kind":"prediction","assetId":"a","pieceId":piece,
            "modelVersion":7,"predictedWeight":10})
    }

    fn measurement(piece: &str) -> Value {
        json!({"kind":"measurement","assetId":"a","pieceId":piece,
            "measuredWeight":12,"targetWeight":11})
    }

    fn tick(asset: &str) -> Value {
        json!({"kind":"tick","assetId":asset})
    }

    fn code(output: &Value, expected: &str) {
        assert_eq!(output["kind"], "diagnostic");
        assert_eq!(output["code"], expected);
    }

    fn complete(c: &mut Correlator, piece: &str, now: u64) -> Value {
        assert_eq!(
            c.process(prediction(piece), now).unwrap()["kind"],
            "pending"
        );
        c.process(measurement(piece), now).unwrap()
    }

    #[test]
    fn both_orders_preserve_every_original_field() {
        for measurement_first in [false, true] {
            let mut c = Correlator::new(config());
            let mut p = prediction("p");
            p["speed"] = json!(3);
            p["temperature"] = json!(22);
            p["speedCoefficient"] = json!(2);
            p["temperatureCoefficient"] = json!(1);
            p["intercept"] = json!(-18);
            p["sampledAt"] = json!("2026-10-20T10:00:00Z");
            p["predictedAt"] = json!("2026-10-20T10:00:01+00:00");
            p["features"] = json!({"custom":[1,2]});
            p["shared"] = json!({"x":true});
            let mut m = measurement("p");
            m["measuredAt"] = json!("2026-10-20T10:00:02Z");
            m["operatorMetadata"] = json!({"line":3});
            m["shared"] = p["shared"].clone();
            let (first, second) = if measurement_first {
                (m.clone(), p.clone())
            } else {
                (p.clone(), m.clone())
            };
            assert_eq!(c.process(first, 0).unwrap()["kind"], "pending");
            let out = c.process(second, 1).unwrap();
            assert_eq!(out["kind"], "correlated");
            assert_eq!(out["residual"], 2.0);
            assert_eq!(out["targetError"], 1.0);
            for source in [&p, &m] {
                for (field, value) in source.as_object().unwrap() {
                    if field != "kind" {
                        assert_eq!(&out[field], value, "{field}");
                    }
                }
            }
            assert!(c.assets["a"].pending.is_empty());
            assert_eq!(c.assets["a"].completed.len(), 1);
        }
    }

    #[test]
    fn key_scope_includes_asset_piece_and_optional_run() {
        let mut c = Correlator::new(config());
        let mut inputs = Vec::new();
        for (asset, run) in [("a", None), ("a", Some("r")), ("b", None)] {
            let mut p = prediction("p");
            let mut m = measurement("p");
            for v in [&mut p, &mut m] {
                v["assetId"] = json!(asset);
                if let Some(run) = run {
                    v["runId"] = json!(run);
                }
            }
            assert_eq!(c.process(p, 0).unwrap()["kind"], "pending");
            inputs.push(m);
        }
        for m in inputs {
            let output = c.process(m.clone(), 1).unwrap();
            assert_eq!(output["kind"], "correlated");
            assert_eq!(output["assetId"], m["assetId"]);
            assert_eq!(output.get("runId"), m.get("runId"));
        }
    }

    #[test]
    fn pending_duplicates_and_conflicts_never_replace_or_refresh() {
        for side in [Side::Prediction, Side::Measurement] {
            let mut c = Correlator::new(config());
            let original = if side == Side::Prediction {
                prediction("p")
            } else {
                measurement("p")
            };
            c.process(original.clone(), 0).unwrap();
            code(&c.process(original.clone(), 8).unwrap(), "duplicate");
            let mut changed = original.clone();
            changed["metadata"] = json!("changed");
            code(&c.process(changed, 9).unwrap(), "conflict");
            assert_eq!(
                c.assets["a"].pending.values().next().unwrap().input,
                original
            );
            let output = c.process(tick("a"), 10).unwrap();
            code(&output, "expired");
            assert_eq!(output["side"], side.name());
            assert!(c.assets.is_empty());
        }
    }

    #[test]
    fn completed_tombstones_keep_both_payloads_until_exact_ttl() {
        let mut c = Correlator::new(config());
        complete(&mut c, "p", 0);
        for mut input in [prediction("p"), measurement("p")] {
            code(&c.process(input.clone(), 18).unwrap(), "duplicate");
            input["extra"] = json!(1);
            code(&c.process(input, 19).unwrap(), "conflict");
        }
        assert_eq!(c.process(prediction("p"), 20).unwrap()["kind"], "pending");
        assert!(c.assets["a"].completed.is_empty());
        assert_eq!(
            c.process(measurement("p"), 21).unwrap()["kind"],
            "correlated"
        );
    }

    #[test]
    fn all_shared_field_conflicts_are_explicit_and_atomic() {
        for field in [
            "speed",
            "modelVersion",
            "predictedWeight",
            "sampledAt",
            "custom",
        ] {
            let mut c = Correlator::new(config());
            let mut p = prediction("p");
            if field == "sampledAt" {
                p[field] = json!("2026-10-20T10:00:00Z");
            } else if p.get(field).is_none() {
                p[field] = json!(1);
            }
            let mut m = measurement("p");
            m[field] = if field == "sampledAt" {
                json!("2026-10-20T10:00:01Z")
            } else {
                json!(99)
            };
            c.process(p.clone(), 0).unwrap();
            let error = c.process(m, 1).unwrap_err();
            assert!(error.contains(field), "{error}");
            assert_eq!(c.assets["a"].pending.values().next().unwrap().input, p);
            assert!(c.assets["a"].completed.is_empty());
            assert_eq!(
                c.process(measurement("p"), 2).unwrap()["kind"],
                "correlated"
            );
        }
    }

    #[test]
    fn derived_fields_cannot_be_silently_overwritten() {
        for (field, good) in [("residual", 2), ("targetError", 1)] {
            for valid in [false, true] {
                let mut c = Correlator::new(config());
                let mut p = prediction("p");
                p[field] = json!(if valid { good } else { 99 });
                c.process(p, 0).unwrap();
                let result = c.process(measurement("p"), 1);
                if valid {
                    assert_eq!(result.unwrap()[field], good);
                } else {
                    assert!(result.unwrap_err().contains(field));
                }
            }
        }
    }

    #[test]
    fn expiration_reports_piece_run_and_side_in_batch() {
        let mut c = Correlator::new(config());
        let mut p = prediction("p");
        p["runId"] = json!("r");
        c.process(p, 0).unwrap();
        c.process(measurement("q"), 1).unwrap();
        assert_eq!(c.process(tick("a"), 9).unwrap()["kind"], "pending");
        let out = c.process(tick("a"), 11).unwrap();
        assert_eq!(out["kind"], "batch");
        let records = out["records"].as_array().unwrap();
        assert_eq!(records.len(), 2);
        for record in records {
            code(record, "expired");
        }
        assert_eq!(records[0]["pieceId"], "p");
        assert_eq!(records[0]["runId"], "r");
        assert_eq!(records[0]["side"], "prediction");
        assert_eq!(records[1]["pieceId"], "q");
        assert_eq!(records[1]["side"], "measurement");
        assert!(records[1].get("runId").is_none());
        assert!(c.assets.is_empty());
    }

    #[test]
    fn expired_opposite_side_is_not_joined_and_new_side_is_retained() {
        let mut c = Correlator::new(config());
        c.process(prediction("p"), 0).unwrap();
        let out = c.process(measurement("p"), 10).unwrap();
        code(&out, "expired");
        assert_eq!(c.assets["a"].pending.len(), 1);
        assert_eq!(
            c.assets["a"].pending.values().next().unwrap().side,
            Side::Measurement
        );
        assert_eq!(
            c.process(prediction("p"), 11).unwrap()["kind"],
            "correlated"
        );
    }

    #[test]
    fn expirations_are_packed_with_current_completion_or_capacity() {
        for capacity in [false, true] {
            let mut cfg = config();
            cfg.max_assets = 1;
            let mut c = Correlator::new(cfg);
            c.process(prediction("old"), 0).unwrap();
            c.process(prediction("live"), 5).unwrap();
            let input = if capacity {
                let mut p = prediction("new");
                p["assetId"] = json!("b");
                p
            } else {
                measurement("live")
            };
            let out = c.process(input, 10).unwrap();
            assert_eq!(out["kind"], "batch");
            let records = out["records"].as_array().unwrap();
            assert_eq!(records.len(), 2);
            code(&records[0], "expired");
            if capacity {
                code(&records[1], "capacity");
            } else {
                assert_eq!(records[1]["kind"], "correlated");
            }
        }
    }

    #[test]
    fn pending_capacity_does_not_evict_and_matching_is_allowed_when_full() {
        let mut c = Correlator::new(config());
        c.process(prediction("p"), 0).unwrap();
        c.process(prediction("q"), 0).unwrap();
        code(&c.process(prediction("r"), 1).unwrap(), "capacity");
        assert_eq!(c.assets["a"].pending.len(), 2);
        assert_eq!(
            c.process(measurement("p"), 2).unwrap()["kind"],
            "correlated"
        );
        assert_eq!(c.process(prediction("r"), 3).unwrap()["kind"], "pending");
    }

    #[test]
    fn completed_capacity_retains_dedup_and_pending_until_retry_after_cleanup() {
        let mut cfg = config();
        cfg.max_completed_per_asset = 1;
        cfg.pending_ttl_ms = 100;
        let mut c = Correlator::new(cfg);
        complete(&mut c, "p", 0);
        c.process(prediction("q"), 1).unwrap();
        code(&c.process(measurement("q"), 2).unwrap(), "capacity");
        code(&c.process(prediction("p"), 19).unwrap(), "duplicate");
        assert_eq!(c.assets["a"].completed.len(), 1);
        assert_eq!(c.assets["a"].pending.len(), 1);
        assert_eq!(
            c.process(measurement("q"), 20).unwrap()["kind"],
            "correlated"
        );
        assert!(!c.assets["a"].completed.contains_key(&Key {
            piece: "p".into(),
            run: None
        }));
    }

    #[test]
    fn assets_are_bounded_and_expired_state_is_reclaimed_on_later_input() {
        let mut cfg = config();
        cfg.max_assets = 1;
        let mut c = Correlator::new(cfg);
        c.process(prediction("p"), 0).unwrap();
        let mut b = prediction("p");
        b["assetId"] = json!("b");
        code(&c.process(b.clone(), 9).unwrap(), "capacity");
        let out = c.process(b, 10).unwrap();
        code(&out, "expired");
        assert_eq!(c.assets.len(), 1);
        assert!(c.assets.contains_key("b"));
        assert!(!c.assets.contains_key("a"));
    }

    #[test]
    fn tombstone_only_asset_cleanup_and_unknown_ticks_do_not_allocate() {
        let mut cfg = config();
        cfg.max_assets = 1;
        let mut c = Correlator::new(cfg);
        assert_eq!(c.process(tick("unknown"), 0).unwrap()["kind"], "pending");
        assert!(c.assets.is_empty());
        complete(&mut c, "p", 0);
        assert_eq!(c.process(tick("unknown"), 19).unwrap()["kind"], "pending");
        assert_eq!(c.assets.len(), 1);
        assert_eq!(c.process(tick("unknown"), 20).unwrap()["kind"], "pending");
        assert!(c.assets.is_empty());
        let mut b = prediction("p");
        b["assetId"] = json!("b");
        assert_eq!(c.process(b, 20).unwrap()["kind"], "pending");
    }

    #[test]
    fn schema_errors_do_not_allocate_or_consume_expiry() {
        let mut invalid = vec![
            Value::Null,
            json!([]),
            json!(1),
            json!({}),
            json!({"kind":"other","assetId":"a"}),
            json!({"kind":"tick"}),
        ];
        for original in [prediction("p"), measurement("p")] {
            for field in ["kind", "assetId", "pieceId"] {
                for value in [
                    Value::Null,
                    json!(1),
                    json!(""),
                    json!("bad\nid"),
                    json!("x".repeat(129)),
                ] {
                    let mut bad = original.clone();
                    bad[field] = value;
                    invalid.push(bad);
                }
                let mut bad = original.clone();
                bad.as_object_mut().unwrap().remove(field);
                invalid.push(bad);
            }
            for value in [
                Value::Null,
                json!(1),
                json!(""),
                json!("bad\tid"),
                json!("x".repeat(129)),
            ] {
                let mut bad = original.clone();
                bad["runId"] = value;
                invalid.push(bad);
            }
        }
        for input in invalid {
            let mut c = Correlator::new(config());
            c.process(prediction("held"), 0).unwrap();
            assert!(c.process(input.clone(), 10).is_err(), "{input}");
            assert_eq!(c.assets.len(), 1);
            assert_eq!(c.assets["a"].pending.len(), 1);
            code(&c.process(tick("a"), 10).unwrap(), "expired");
        }
    }

    #[test]
    fn numeric_schema_and_unsigned_positive_model_version() {
        for (original, fields) in [
            (prediction("p"), vec!["predictedWeight"]),
            (measurement("p"), vec!["measuredWeight", "targetWeight"]),
        ] {
            for field in fields {
                for value in [
                    Value::Null,
                    json!("NaN"),
                    json!("Infinity"),
                    json!("12"),
                    json!([]),
                    json!(true),
                ] {
                    let mut bad = original.clone();
                    bad[field] = value;
                    assert!(Correlator::new(config()).process(bad, 0).is_err());
                }
                let mut bad = original.clone();
                bad.as_object_mut().unwrap().remove(field);
                assert!(Correlator::new(config()).process(bad, 0).is_err());
            }
        }
        for value in [
            Value::Null,
            json!(0),
            json!(-1),
            json!(1.5),
            json!("7"),
            json!(1.0),
        ] {
            let mut bad = prediction("p");
            bad["modelVersion"] = value;
            assert!(Correlator::new(config()).process(bad, 0).is_err());
        }
        let mut bad = prediction("p");
        bad.as_object_mut().unwrap().remove("modelVersion");
        assert!(Correlator::new(config()).process(bad, 0).is_err());
        let mut good = prediction("p");
        good["modelVersion"] = json!(u64::MAX);
        good["predictedWeight"] = json!(-1);
        assert_eq!(
            Correlator::new(config()).process(good, 0).unwrap()["kind"],
            "pending"
        );
    }

    #[test]
    fn timestamps_are_optional_but_explicitly_validated() {
        for field in ["sampledAt", "predictedAt", "measuredAt"] {
            for value in [
                Value::Null,
                json!(0),
                json!(""),
                json!("yesterday"),
                json!("2026-10-20T10:00:00"),
                json!("2026-02-30T10:00:00Z"),
            ] {
                let mut input = prediction("p");
                input[field] = value;
                assert!(Correlator::new(config()).process(input, 0).is_err());
            }
            let mut good = measurement("p");
            good[field] = json!("2026-10-20T10:00:00.123+05:30");
            assert_eq!(
                Correlator::new(config()).process(good, 0).unwrap()["kind"],
                "pending"
            );
        }
    }

    #[test]
    fn identifier_byte_boundaries_and_large_clock_are_supported() {
        let mut c = Correlator::new(config());
        let mut p = prediction(&"p".repeat(128));
        p["assetId"] = json!("é".repeat(64));
        p["runId"] = json!("r".repeat(128));
        c.process(p, u64::MAX - 10).unwrap();
        let out = c.process(tick("unknown"), u64::MAX).unwrap();
        code(&out, "expired");
        assert!(c.assets.is_empty());
    }

    #[test]
    fn overflow_in_either_derived_value_is_an_error_without_state_loss() {
        for residual_overflow in [false, true] {
            for measurement_first in [false, true] {
                let mut c = Correlator::new(config());
                let mut p = prediction("p");
                let mut m = measurement("p");
                m["measuredWeight"] = json!(f64::MAX);
                if residual_overflow {
                    p["predictedWeight"] = json!(-f64::MAX);
                } else {
                    m["targetWeight"] = json!(-f64::MAX);
                }
                let (first, second) = if measurement_first { (m, p) } else { (p, m) };
                c.process(first.clone(), 0).unwrap();
                assert!(c.process(second, 1).unwrap_err().contains("overflow"));
                assert_eq!(c.assets["a"].pending.values().next().unwrap().input, first);
                assert!(c.assets["a"].completed.is_empty());
            }
        }
    }

    #[test]
    fn failed_merge_does_not_consume_other_expiration_diagnostics() {
        let mut c = Correlator::new(config());
        c.process(prediction("old"), 0).unwrap();
        let mut p = prediction("live");
        p["custom"] = json!(1);
        c.process(p, 5).unwrap();
        let mut m = measurement("live");
        m["custom"] = json!(2);
        assert!(c.process(m, 10).is_err());
        assert_eq!(c.assets["a"].pending.len(), 2);
        let out = c.process(tick("a"), 10).unwrap();
        code(&out, "expired");
        assert_eq!(out["pieceId"], "old");
    }
}
