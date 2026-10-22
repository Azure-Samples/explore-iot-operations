// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::common::{
    diagnostic, identifier, number, pack, pending_output, string, timestamp, version, Config,
    Result, Role,
};

#[derive(Clone, Debug, PartialEq)]
struct Model {
    version: u64,
    speed_coefficient: f64,
    temperature_coefficient: f64,
    intercept: f64,
}

#[derive(Debug, PartialEq)]
struct Asset {
    model: Model,
    updates: BTreeMap<String, Value>,
}

/// Volatile model state. Only an externally authenticated, approved source may
/// feed model events; payload fields are not proof of authorization.
pub struct Predictor {
    max_assets: usize,
    max_updates_per_asset: usize,
    assets: BTreeMap<String, Asset>,
}

impl Predictor {
    pub fn new(config: Config) -> Result<Self> {
        if config.role != Role::VersionedPredictor {
            return Err("predictor requires versioned-predictor role".into());
        }
        if config.max_assets == 0 || config.max_assets > 1024 {
            return Err("maxAssets must be in 1..=1024".into());
        }
        if config.max_updates_per_asset == 0 || config.max_updates_per_asset > 4096 {
            return Err("maxUpdatesPerAsset must be in 1..=4096".into());
        }
        if config.initial_models.len() > config.max_assets {
            return Err("too many initialModels".into());
        }

        let mut assets = BTreeMap::new();
        for initial in config.initial_models {
            identifier(&initial.asset_id)?;
            if initial.model_version == 0
                || ![
                    initial.speed_coefficient,
                    initial.temperature_coefficient,
                    initial.intercept,
                ]
                .iter()
                .all(|value| value.is_finite())
            {
                return Err(
                    "initial model requires positive version and finite coefficients".into(),
                );
            }
            if assets.contains_key(&initial.asset_id) {
                return Err("duplicate initial model assetId".into());
            }
            assets.insert(
                initial.asset_id,
                Asset {
                    model: Model {
                        version: initial.model_version,
                        speed_coefficient: initial.speed_coefficient,
                        temperature_coefficient: initial.temperature_coefficient,
                        intercept: initial.intercept,
                    },
                    updates: BTreeMap::new(),
                },
            );
        }
        Ok(Self {
            max_assets: config.max_assets,
            max_updates_per_asset: config.max_updates_per_asset,
            assets,
        })
    }

    pub fn process(&mut self, input: Value, _now_ms: u64) -> Result<Value> {
        if !input.is_object() {
            return Err("payload must be a JSON object".into());
        }
        let kind = string(&input, "kind")?;
        let asset_id = string(&input, "assetId")?;
        if input.get("runId").is_some() {
            string(&input, "runId")?;
        }
        for field in ["sampledAt", "predictedAt"] {
            if input.get(field).is_some() {
                timestamp(string(&input, field)?)?;
            }
        }

        let output = match kind {
            "reading" => self.reading(&input, asset_id)?,
            "model" => self.apply_model(&input, asset_id)?,
            "tick" => pending_output(),
            _ => return Err(format!("unsupported predictor kind: {kind}")),
        };
        Ok(pack(vec![output]))
    }

    fn reading(&self, input: &Value, asset_id: &str) -> Result<Value> {
        string(input, "pieceId")?;
        let speed = number(input, "speed")?;
        let temperature = number(input, "temperature")?;
        if input.get("modelVersion").is_some() {
            version(input, "modelVersion")?;
        }
        for field in [
            "speedCoefficient",
            "temperatureCoefficient",
            "intercept",
            "predictedWeight",
        ] {
            if input.get(field).is_some() {
                number(input, field)?;
            }
        }
        let Some(asset) = self.assets.get(asset_id) else {
            return Ok(diagnostic(
                "noActiveModel",
                asset_id,
                "no active model for asset",
            ));
        };
        let model = &asset.model;
        let speed_term = speed * model.speed_coefficient;
        let temperature_term = temperature * model.temperature_coefficient;
        let sum = speed_term + temperature_term;
        let predicted_weight = sum + model.intercept;
        if ![speed_term, temperature_term, sum, predicted_weight]
            .iter()
            .all(|value| value.is_finite())
        {
            return Err("prediction arithmetic overflow".into());
        }
        if input.get("modelVersion").is_some() && version(input, "modelVersion")? != model.version {
            return Err("reading conflicts with reserved field modelVersion".into());
        }
        for (field, expected) in [
            ("speedCoefficient", model.speed_coefficient),
            ("temperatureCoefficient", model.temperature_coefficient),
            ("intercept", model.intercept),
            ("predictedWeight", predicted_weight),
        ] {
            if input.get(field).is_some() && number(input, field)? != expected {
                return Err(format!("reading conflicts with reserved field {field}"));
            }
        }

        let mut output = input.clone();
        let object = output.as_object_mut().expect("validated object");
        object.insert("kind".into(), json!("prediction"));
        // Equal reserved values remain untouched, preserving their JSON representation.
        for (field, value) in [
            ("modelVersion", json!(model.version)),
            ("speedCoefficient", json!(model.speed_coefficient)),
            (
                "temperatureCoefficient",
                json!(model.temperature_coefficient),
            ),
            ("intercept", json!(model.intercept)),
            ("predictedWeight", json!(predicted_weight)),
        ] {
            object.entry(field.to_owned()).or_insert(value);
        }
        Ok(output)
    }

    fn apply_model(&mut self, input: &Value, asset_id: &str) -> Result<Value> {
        let update_id = string(input, "updateId")?;
        let expected = version(input, "expectedModelVersion")?;
        let model = Model {
            version: version(input, "modelVersion")?,
            speed_coefficient: number(input, "speedCoefficient")?,
            temperature_coefficient: number(input, "temperatureCoefficient")?,
            intercept: number(input, "intercept")?,
        };
        if input.get("modelProposal").is_some() {
            return Err("model events must be flat, not modelProposal".into());
        }
        let existing = self.assets.get(asset_id);
        if let Some(original) = existing.and_then(|asset| asset.updates.get(update_id)) {
            return Ok(if original == input {
                diagnostic(
                    "duplicateUpdate",
                    asset_id,
                    "updateId already applied with identical payload",
                )
            } else {
                diagnostic(
                    "conflictingUpdate",
                    asset_id,
                    "updateId already applied with different payload",
                )
            });
        }

        let active_version = existing.map_or(0, |asset| asset.model.version);
        if model.version <= active_version {
            return Ok(diagnostic(
                "staleUpdate",
                asset_id,
                "modelVersion is not newer than active model",
            ));
        }
        if expected != active_version || expected.checked_add(1) != Some(model.version) {
            return Ok(diagnostic(
                "versionConflict",
                asset_id,
                "expected active version and its immediate successor",
            ));
        }
        if existing.is_none() && self.assets.len() >= self.max_assets {
            return Ok(diagnostic(
                "capacity",
                asset_id,
                "maxAssets reached; no model was evicted",
            ));
        }
        if existing.is_some_and(|asset| asset.updates.len() >= self.max_updates_per_asset) {
            return Ok(diagnostic(
                "capacity",
                asset_id,
                "maxUpdatesPerAsset reached; no history was evicted",
            ));
        }

        // All fallible validation precedes mutation; accepted payloads never expire.
        let accepted_version = model.version;
        if let Some(asset) = self.assets.get_mut(asset_id) {
            asset.updates.insert(update_id.to_owned(), input.clone());
            asset.model = model;
        } else {
            let mut updates = BTreeMap::new();
            updates.insert(update_id.to_owned(), input.clone());
            self.assets
                .insert(asset_id.to_owned(), Asset { model, updates });
        }
        Ok(json!({
            "kind": "modelApplied",
            "assetId": asset_id,
            "updateId": update_id,
            "modelVersion": accepted_version,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::InitialModel;

    fn config() -> Config {
        Config::parse(r#"{"role":"versioned-predictor"}"#).unwrap()
    }

    fn initial(asset_id: &str, model_version: u64) -> InitialModel {
        InitialModel {
            asset_id: asset_id.into(),
            model_version,
            speed_coefficient: 2.0,
            temperature_coefficient: 3.0,
            intercept: 4.0,
        }
    }

    fn bootstrapped() -> Predictor {
        let mut config = config();
        config.initial_models.push(initial("a", 7));
        Predictor::new(config).unwrap()
    }

    fn reading() -> Value {
        json!({"kind":"reading","assetId":"a","pieceId":"p","speed":5,"temperature":6})
    }

    fn update(id: &str, expected: u64, next: u64) -> Value {
        json!({
            "kind":"model", "assetId":"a", "updateId":id,
            "expectedModelVersion":expected, "modelVersion":next,
            "speedCoefficient":2, "temperatureCoefficient":3, "intercept":4,
        })
    }

    fn assert_code(output: Value, code: &str) {
        assert_eq!(output["kind"], "diagnostic");
        assert_eq!(output["code"], code);
        assert!(output["assetId"].is_string());
    }

    #[test]
    fn constructor_accepts_empty_and_arbitrary_positive_bootstrap_versions() {
        assert!(Predictor::new(config()).unwrap().assets.is_empty());
        let mut predictor = bootstrapped();
        assert!(predictor.assets["a"].updates.is_empty());
        assert_eq!(predictor.process(reading(), 0).unwrap()["modelVersion"], 7);
        assert_eq!(
            predictor.process(update("u8", 7, 8), 0).unwrap(),
            json!({"kind":"modelApplied","assetId":"a","updateId":"u8","modelVersion":8})
        );
        let mut config = config();
        config.initial_models.push(initial("a", u64::MAX));
        assert!(Predictor::new(config).is_ok());
    }

    #[test]
    fn constructor_rejects_invalid_capacities_and_role() {
        for capacity in [0, 1025, usize::MAX] {
            let mut config = config();
            config.max_assets = capacity;
            assert!(Predictor::new(config).is_err());
        }
        for capacity in [0, 4097, usize::MAX] {
            let mut config = config();
            config.max_updates_per_asset = capacity;
            assert!(Predictor::new(config).is_err());
        }
        let mut config = config();
        config.max_assets = 1024;
        config.max_updates_per_asset = 4096;
        assert!(Predictor::new(config.clone()).is_ok());
        config.role = Role::AlignByTime;
        assert!(Predictor::new(config).is_err());
    }

    #[test]
    fn constructor_rejects_invalid_initial_models() {
        for id in ["", "bad\nid", &"x".repeat(129)] {
            let mut config = config();
            config.initial_models.push(initial(id, 7));
            assert!(Predictor::new(config).is_err());
        }
        let mut base = config();
        base.initial_models.push(initial("a", 7));
        let mut invalid = base.clone();
        invalid.initial_models[0].model_version = 0;
        assert!(Predictor::new(invalid).is_err());
        for field in 0..3 {
            for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
                let mut invalid = base.clone();
                let model = &mut invalid.initial_models[0];
                match field {
                    0 => model.speed_coefficient = value,
                    1 => model.temperature_coefficient = value,
                    _ => model.intercept = value,
                }
                assert!(Predictor::new(invalid).is_err());
            }
        }
        let mut invalid = base.clone();
        invalid.initial_models.push(initial("a", 8));
        assert!(Predictor::new(invalid).is_err());
        let mut invalid = base;
        invalid.max_assets = 1;
        invalid.initial_models.push(initial("b", 1));
        assert!(Predictor::new(invalid).is_err());
    }

    #[test]
    fn missing_model_is_diagnostic_and_does_not_consume_asset_capacity() {
        let mut config = config();
        config.max_assets = 1;
        let mut predictor = Predictor::new(config).unwrap();
        for asset_id in ["a", "b", "c"] {
            let mut input = reading();
            input["assetId"] = json!(asset_id);
            assert_code(predictor.process(input, 0).unwrap(), "noActiveModel");
        }
        assert!(predictor.assets.is_empty());
        assert_eq!(
            predictor.process(update("u1", 0, 1), 0).unwrap()["kind"],
            "modelApplied"
        );
        assert_eq!(
            predictor.process(reading(), 0).unwrap()["predictedWeight"],
            32.0
        );
    }

    #[test]
    fn invalid_readings_are_errors_even_without_an_active_model() {
        let mut predictor = Predictor::new(config()).unwrap();
        for (field, value) in [
            ("pieceId", json!("")),
            ("speed", json!("5")),
            ("temperature", Value::Null),
            ("runId", json!(false)),
            ("sampledAt", json!("invalid")),
            ("predictedAt", json!(0)),
            ("modelVersion", json!("7")),
            ("predictedWeight", json!("32")),
        ] {
            let mut input = reading();
            input[field] = value;
            assert!(predictor.process(input, 0).is_err(), "{field}");
            assert!(predictor.assets.is_empty());
        }
    }

    #[test]
    fn activated_coefficients_replace_bootstrap_and_state_is_volatile() {
        let mut predictor = bootstrapped();
        let mut replacement = update("u8", 7, 8);
        replacement["speedCoefficient"] = json!(-1.5);
        replacement["temperatureCoefficient"] = json!(0.25);
        replacement["intercept"] = json!(10);
        replacement["predictedAt"] = json!("2026-10-20T10:24:34Z");
        predictor.process(replacement, 0).unwrap();
        let output = predictor.process(reading(), 0).unwrap();
        assert_eq!(output["modelVersion"], 8);
        assert_eq!(output["speedCoefficient"], -1.5);
        assert_eq!(output["temperatureCoefficient"], 0.25);
        assert_eq!(output["intercept"], 10.0);
        assert_eq!(output["predictedWeight"], 4.0);
        assert_code(
            predictor.process(update("stale", 7, 8), 0).unwrap(),
            "staleUpdate",
        );
        assert_eq!(predictor.process(reading(), 0).unwrap(), output);
        drop(predictor);
        let mut restarted = Predictor::new(config()).unwrap();
        assert_code(restarted.process(reading(), 0).unwrap(), "noActiveModel");
        let mut restarted = bootstrapped();
        assert_eq!(restarted.process(reading(), 0).unwrap()["modelVersion"], 7);
    }

    #[test]
    fn preserves_all_original_fields_except_reading_kind() {
        let mut predictor = bootstrapped();
        let mut input = reading();
        input["runId"] = json!("run-1");
        input["sampledAt"] = json!("2026-10-20T10:24:34.803-07:00");
        input["predictedAt"] = json!("2026-10-20T17:25:00Z");
        input["customer"] = json!({"nested":[1,null,{"ok":true}]});
        input["modelVersion"] = json!(7);
        input["speedCoefficient"] = json!(2);
        input["temperatureCoefficient"] = json!(3);
        input["intercept"] = json!(4);
        input["predictedWeight"] = json!(32);
        let output = predictor.process(input.clone(), 0).unwrap();
        assert_eq!(output["kind"], "prediction");
        for (key, value) in input.as_object().unwrap() {
            if key != "kind" {
                assert_eq!(&output[key], value, "{key}");
            }
        }
        let mut plain = reading();
        plain["speed"] = json!(-5);
        assert_eq!(
            predictor.process(plain, 0).unwrap()["predictedWeight"],
            12.0
        );
    }

    #[test]
    fn rejects_each_spoofed_reserved_field_without_changing_state() {
        let mut predictor = bootstrapped();
        for field in [
            "modelVersion",
            "speedCoefficient",
            "temperatureCoefficient",
            "intercept",
            "predictedWeight",
        ] {
            let before = format!("{:?}", predictor.assets);
            let mut input = reading();
            input[field] = json!(999);
            assert!(predictor.process(input, 0).is_err(), "{field}");
            assert_eq!(format!("{:?}", predictor.assets), before);
        }
        assert_eq!(predictor.process(reading(), 0).unwrap()["modelVersion"], 7);
    }

    #[test]
    fn requires_all_reading_and_model_fields() {
        let mut predictor = bootstrapped();
        for (template, fields) in [
            (
                reading(),
                vec!["kind", "assetId", "pieceId", "speed", "temperature"],
            ),
            (
                update("u8", 7, 8),
                vec![
                    "kind",
                    "assetId",
                    "updateId",
                    "expectedModelVersion",
                    "modelVersion",
                    "speedCoefficient",
                    "temperatureCoefficient",
                    "intercept",
                ],
            ),
        ] {
            for field in fields {
                let mut input = template.clone();
                input.as_object_mut().unwrap().remove(field);
                assert!(predictor.process(input, 0).is_err(), "{field}");
            }
        }
        assert_eq!(predictor.assets["a"].model.version, 7);
        assert!(predictor.assets["a"].updates.is_empty());
    }

    #[test]
    fn validates_all_required_and_optional_identifiers() {
        let mut predictor = bootstrapped();
        for (template, fields) in [
            (reading(), vec!["assetId", "pieceId", "runId"]),
            (update("u8", 7, 8), vec!["assetId", "updateId", "runId"]),
            (
                json!({"kind":"tick","assetId":"a"}),
                vec!["assetId", "runId"],
            ),
        ] {
            for field in fields {
                for value in [
                    json!(""),
                    json!("bad\u{0000}id"),
                    json!("x".repeat(129)),
                    Value::Null,
                    json!(1),
                    json!({}),
                    json!(true),
                ] {
                    let mut input = template.clone();
                    input[field] = value;
                    assert!(predictor.process(input, 0).is_err(), "{field}");
                }
            }
        }
        let mut input = reading();
        input["pieceId"] = json!("x".repeat(128));
        input["runId"] = json!("valid");
        assert!(predictor.process(input, 0).is_ok());
    }

    #[test]
    fn validates_optional_rfc3339_timestamps_on_every_kind() {
        let mut predictor = bootstrapped();
        for template in [
            reading(),
            update("u8", 7, 8),
            json!({"kind":"tick","assetId":"a"}),
        ] {
            for field in ["sampledAt", "predictedAt"] {
                for value in [
                    Value::Null,
                    json!(0),
                    json!(""),
                    json!("2026-10-20"),
                    json!("2026-10-20T10:24:34"),
                    json!("2026-02-30T10:24:34Z"),
                    json!("2026-10-20T10:24:34+25:00"),
                ] {
                    let mut input = template.clone();
                    input[field] = value;
                    assert!(predictor.process(input, 0).is_err(), "{field}");
                }
            }
        }
        assert!(predictor.assets["a"].updates.is_empty());
        for field in ["sampledAt", "predictedAt"] {
            for value in ["2026-10-20T10:24:34Z", "2026-10-20T10:24:34.123+05:30"] {
                let mut input = reading();
                input[field] = json!(value);
                assert_eq!(predictor.process(input, 0).unwrap()[field], value);
            }
        }
    }

    #[test]
    fn rejects_invalid_numbers_including_numeric_strings() {
        let mut predictor = bootstrapped();
        for (template, fields) in [
            (
                reading(),
                vec![
                    "speed",
                    "temperature",
                    "speedCoefficient",
                    "temperatureCoefficient",
                    "intercept",
                    "predictedWeight",
                ],
            ),
            (
                update("u8", 7, 8),
                vec!["speedCoefficient", "temperatureCoefficient", "intercept"],
            ),
        ] {
            for field in fields {
                for value in [
                    Value::Null,
                    json!(true),
                    json!([]),
                    json!({}),
                    json!("1.5"),
                    json!("NaN"),
                    json!("Infinity"),
                    json!("1e999"),
                ] {
                    let mut input = template.clone();
                    input[field] = value;
                    assert!(predictor.process(input, 0).is_err(), "{field}");
                }
            }
        }
        assert!(predictor.assets["a"].updates.is_empty());
    }

    #[test]
    fn versions_must_be_unsigned_json_integers() {
        let mut predictor = bootstrapped();
        for (template, fields) in [
            (reading(), vec!["modelVersion"]),
            (
                update("u8", 7, 8),
                vec!["expectedModelVersion", "modelVersion"],
            ),
        ] {
            for field in fields {
                for value in [
                    Value::Null,
                    json!(-1),
                    json!(7.0),
                    json!(1.5),
                    json!("7"),
                    json!(true),
                    json!({}),
                    json!(18446744073709551616.0_f64),
                ] {
                    let mut input = template.clone();
                    input[field] = value;
                    assert!(predictor.process(input, 0).is_err(), "{field}");
                }
            }
        }
        assert!(predictor.assets["a"].updates.is_empty());
    }

    #[test]
    fn arithmetic_overflow_is_an_error_not_a_null_prediction() {
        for (speed_coefficient, temperature_coefficient, intercept, speed, temperature) in [
            (2.0, 0.0, 0.0, f64::MAX, 0.0),
            (0.0, 2.0, 0.0, 0.0, f64::MAX),
            (1.0, 1.0, 0.0, f64::MAX, f64::MAX),
            (1.0, 0.0, f64::MAX, f64::MAX, 0.0),
            (2.0, -2.0, 0.0, f64::MAX, f64::MAX),
        ] {
            let mut config = config();
            config.initial_models.push(InitialModel {
                asset_id: "a".into(),
                model_version: 7,
                speed_coefficient,
                temperature_coefficient,
                intercept,
            });
            let mut predictor = Predictor::new(config).unwrap();
            let before = format!("{:?}", predictor.assets);
            let mut input = reading();
            input["speed"] = json!(speed);
            input["temperature"] = json!(temperature);
            assert!(predictor
                .process(input, 0)
                .unwrap_err()
                .contains("overflow"));
            assert_eq!(format!("{:?}", predictor.assets), before);
        }
    }

    #[test]
    fn only_contiguous_expected_versions_are_applied() {
        let mut predictor = Predictor::new(config()).unwrap();
        for input in [
            update("gap", 0, 7),
            update("wrong", 1, 2),
            update("wrong", 1, 1),
        ] {
            assert_code(predictor.process(input, 0).unwrap(), "versionConflict");
            assert!(predictor.assets.is_empty());
        }
        assert_code(
            predictor.process(update("zero", 0, 0), 0).unwrap(),
            "staleUpdate",
        );
        assert_eq!(
            predictor.process(update("u1", 0, 1), 0).unwrap()["modelVersion"],
            1
        );
        for input in [update("gap", 1, 3), update("wrong", 0, 2)] {
            assert_code(predictor.process(input, 0).unwrap(), "versionConflict");
            assert_eq!(predictor.assets["a"].model.version, 1);
            assert_eq!(predictor.assets["a"].updates.len(), 1);
        }
        assert_eq!(
            predictor.process(update("u2", 1, 2), 0).unwrap()["modelVersion"],
            2
        );
        for input in [update("older", 0, 1), update("same", 1, 2)] {
            assert_code(predictor.process(input, 0).unwrap(), "staleUpdate");
        }
        assert_eq!(predictor.assets["a"].updates.len(), 2);
    }

    #[test]
    fn deduplicates_full_original_payload_even_after_newer_updates() {
        let mut predictor = Predictor::new(config()).unwrap();
        let mut first = update("u1", 0, 1);
        first["approval"] = json!({"source":"trusted","revision":1});
        first["runId"] = json!("run");
        first["sampledAt"] = json!("2026-10-20T10:24:34Z");
        predictor.process(first.clone(), 0).unwrap();
        predictor.process(update("u2", 1, 2), 1).unwrap();
        assert_code(
            predictor.process(first.clone(), u64::MAX).unwrap(),
            "duplicateUpdate",
        );
        for (field, value) in [
            ("speedCoefficient", json!(9)),
            ("modelVersion", json!(3)),
            ("expectedModelVersion", json!(2)),
            ("runId", json!("other")),
            ("sampledAt", json!("2026-10-20T10:24:35Z")),
            ("approval", json!({"source":"trusted","revision":2})),
            ("extra", json!(true)),
        ] {
            let mut changed = first.clone();
            changed[field] = value;
            assert_code(predictor.process(changed, 1).unwrap(), "conflictingUpdate");
        }
        let mut removed = first.clone();
        removed.as_object_mut().unwrap().remove("approval");
        assert_code(predictor.process(removed, 1).unwrap(), "conflictingUpdate");
        assert_eq!(predictor.assets["a"].updates["u1"], first);
        assert_eq!(predictor.assets["a"].model.version, 2);
    }

    #[test]
    fn capacity_never_evicts_models_or_deduplication_history() {
        let mut config = config();
        config.max_assets = 1;
        config.max_updates_per_asset = 1;
        let mut predictor = Predictor::new(config).unwrap();
        let first = update("u1", 0, 1);
        predictor.process(first.clone(), 0).unwrap();
        let before = format!("{:?}", predictor.assets);
        assert_code(
            predictor.process(update("u2", 1, 2), 1).unwrap(),
            "capacity",
        );
        let mut another_asset = update("u1", 0, 1);
        another_asset["assetId"] = json!("b");
        assert_code(predictor.process(another_asset, 1).unwrap(), "capacity");
        assert_code(
            predictor.process(first.clone(), 1).unwrap(),
            "duplicateUpdate",
        );
        let mut conflict = first;
        conflict["intercept"] = json!(10);
        assert_code(predictor.process(conflict, 1).unwrap(), "conflictingUpdate");
        assert_code(
            predictor.process(update("old", 0, 1), 1).unwrap(),
            "staleUpdate",
        );
        assert_code(
            predictor.process(update("gap", 1, 3), 1).unwrap(),
            "versionConflict",
        );
        assert_eq!(
            predictor.process(reading(), u64::MAX).unwrap()["modelVersion"],
            1
        );
        assert_eq!(format!("{:?}", predictor.assets), before);
    }

    #[test]
    fn bootstrap_counts_toward_assets_but_not_update_history() {
        let mut config = config();
        config.max_assets = 1;
        config.max_updates_per_asset = 1;
        config.initial_models.push(initial("a", 7));
        let mut predictor = Predictor::new(config).unwrap();
        let mut other = update("other", 0, 1);
        other["assetId"] = json!("b");
        assert_code(predictor.process(other, 0).unwrap(), "capacity");
        assert_eq!(
            predictor.process(update("u8", 7, 8), 0).unwrap()["modelVersion"],
            8
        );
        assert_code(
            predictor.process(update("u9", 8, 9), 0).unwrap(),
            "capacity",
        );
        assert_eq!(predictor.assets["a"].model.version, 8);
    }

    #[test]
    fn update_ids_are_scoped_per_asset() {
        let mut predictor = Predictor::new(config()).unwrap();
        for asset_id in ["a", "b"] {
            let mut input = update("shared", 0, 1);
            input["assetId"] = json!(asset_id);
            assert_eq!(predictor.process(input, 0).unwrap()["kind"], "modelApplied");
        }
        assert_eq!(predictor.assets.len(), 2);
    }

    #[test]
    fn invalid_updates_are_atomic_and_do_not_reserve_ids() {
        let mut predictor = bootstrapped();
        let before = format!("{:?}", predictor.assets);
        for (field, value) in [
            ("intercept", json!("bad")),
            ("temperatureCoefficient", Value::Null),
            ("expectedModelVersion", json!(-1)),
            ("updateId", json!("")),
            ("sampledAt", json!("bad")),
            ("predictedAt", Value::Null),
            ("modelProposal", json!({"modelVersion":8})),
        ] {
            let mut input = update("u8", 7, 8);
            input[field] = value;
            assert!(predictor.process(input, 0).is_err(), "{field}");
            assert_eq!(format!("{:?}", predictor.assets), before);
        }
        assert_eq!(
            predictor.process(update("u8", 7, 8), 0).unwrap()["kind"],
            "modelApplied"
        );
        let mut malformed_duplicate = update("u8", 7, 8);
        malformed_duplicate["speedCoefficient"] = json!("2");
        assert!(predictor.process(malformed_duplicate, 0).is_err());
        assert_eq!(predictor.assets["a"].updates["u8"], update("u8", 7, 8));

        let mut empty = Predictor::new(config()).unwrap();
        let mut invalid = update("u1", 0, 1);
        invalid["intercept"] = json!("4");
        assert!(empty.process(invalid, 0).is_err());
        assert!(empty.assets.is_empty());
        assert_eq!(
            empty.process(update("u1", 0, 1), 0).unwrap()["kind"],
            "modelApplied"
        );
    }

    #[test]
    fn max_version_does_not_wrap_or_reset() {
        let mut config = config();
        config.initial_models.push(initial("a", u64::MAX - 1));
        let mut predictor = Predictor::new(config).unwrap();
        assert_eq!(
            predictor
                .process(update("last", u64::MAX - 1, u64::MAX), 0)
                .unwrap()["modelVersion"],
            json!(u64::MAX)
        );
        let before = format!("{:?}", predictor.assets);
        for next in [0, 1, u64::MAX] {
            assert_code(
                predictor
                    .process(update("wrap", u64::MAX, next), 0)
                    .unwrap(),
                "staleUpdate",
            );
        }
        assert_eq!(format!("{:?}", predictor.assets), before);
    }

    #[test]
    fn tick_requires_asset_id_and_never_changes_or_expires_models() {
        let mut predictor = bootstrapped();
        predictor.process(update("u8", 7, 8), 0).unwrap();
        let before = format!("{:?}", predictor.assets);
        for asset_id in ["a", "unknown"] {
            assert_eq!(
                predictor
                    .process(json!({"kind":"tick","assetId":asset_id}), u64::MAX)
                    .unwrap(),
                pending_output()
            );
        }
        assert!(predictor.process(json!({"kind":"tick"}), 0).is_err());
        assert_eq!(format!("{:?}", predictor.assets), before);
        assert_code(
            predictor.process(update("u8", 7, 8), u64::MAX).unwrap(),
            "duplicateUpdate",
        );
        assert_eq!(
            predictor.process(reading(), u64::MAX).unwrap()["modelVersion"],
            8
        );
    }

    #[test]
    fn rejects_nonobjects_unknown_kinds_and_nested_model_proposals() {
        let mut predictor = Predictor::new(config()).unwrap();
        for input in [
            Value::Null,
            json!([]),
            json!(1),
            json!("reading"),
            json!({"kind":"modelProposal","assetId":"a"}),
            json!({"kind":true,"assetId":"a"}),
            json!({"kind":"model","assetId":"a","modelProposal":update("u1",0,1)}),
        ] {
            assert!(predictor.process(input, 0).is_err());
            assert!(predictor.assets.is_empty());
        }
    }
}
