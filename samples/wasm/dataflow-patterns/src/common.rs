// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub type Result<T> = std::result::Result<T, String>;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub role: Role,
    #[serde(default = "assets")]
    pub max_assets: usize,
    #[serde(default = "pending")]
    pub max_pending_per_asset: usize,
    #[serde(default = "history")]
    pub max_history_per_asset: usize,
    #[serde(default = "completed")]
    pub max_completed_per_asset: usize,
    #[serde(default = "updates")]
    pub max_updates_per_asset: usize,
    #[serde(default = "ttl")]
    pub pending_ttl_ms: u64,
    #[serde(default = "ttl")]
    pub completed_ttl_ms: u64,
    #[serde(default = "lateness")]
    pub allowed_lateness_ms: u64,
    #[serde(default = "age")]
    pub max_context_age_ms: u64,
    #[serde(default = "skew")]
    pub max_future_skew_ms: u64,
    #[serde(default)]
    pub initial_models: Vec<InitialModel>,
}

fn assets() -> usize {
    128
}
fn pending() -> usize {
    256
}
fn history() -> usize {
    256
}
fn completed() -> usize {
    512
}
fn updates() -> usize {
    512
}
fn ttl() -> u64 {
    60_000
}
fn lateness() -> u64 {
    2_000
}
fn age() -> u64 {
    5_000
}
fn skew() -> u64 {
    30_000
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Role {
    AlignByTime,
    CorrelateById,
    VersionedPredictor,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InitialModel {
    pub asset_id: String,
    pub model_version: u64,
    pub speed_coefficient: f64,
    pub temperature_coefficient: f64,
    pub intercept: f64,
}

impl Config {
    pub fn parse(text: &str) -> Result<Self> {
        let c: Self =
            serde_json::from_str(text).map_err(|e| format!("invalid configuration: {e}"))?;
        for (name, value, max) in [
            ("maxAssets", c.max_assets, 1024),
            ("maxPendingPerAsset", c.max_pending_per_asset, 4096),
            ("maxHistoryPerAsset", c.max_history_per_asset, 4096),
            ("maxCompletedPerAsset", c.max_completed_per_asset, 4096),
            ("maxUpdatesPerAsset", c.max_updates_per_asset, 4096),
        ] {
            if value == 0 || value > max {
                return Err(format!("{name} must be in 1..={max}"));
            }
        }
        for (name, value) in [
            ("pendingTtlMs", c.pending_ttl_ms),
            ("completedTtlMs", c.completed_ttl_ms),
            ("maxContextAgeMs", c.max_context_age_ms),
            ("maxFutureSkewMs", c.max_future_skew_ms),
        ] {
            if value == 0 || value > 86_400_000 {
                return Err(format!("{name} must be in 1..=86400000"));
            }
        }
        if c.allowed_lateness_ms > 60_000 || c.allowed_lateness_ms >= c.pending_ttl_ms {
            return Err("allowedLatenessMs must be <=60000 and less than pendingTtlMs".into());
        }
        if c.initial_models.len() > c.max_assets {
            return Err("too many initialModels".into());
        }
        let mut ids = std::collections::BTreeSet::new();
        for m in &c.initial_models {
            identifier(&m.asset_id)?;
            if !ids.insert(&m.asset_id) {
                return Err("duplicate initial model assetId".into());
            }
            if m.model_version == 0
                || ![m.speed_coefficient, m.temperature_coefficient, m.intercept]
                    .iter()
                    .all(|x| x.is_finite())
            {
                return Err(
                    "initial model requires positive version and finite coefficients".into(),
                );
            }
        }
        if c.role != Role::VersionedPredictor && !c.initial_models.is_empty() {
            return Err("initialModels is only valid for versioned-predictor".into());
        }
        Ok(c)
    }
}

pub fn identifier(s: &str) -> Result<()> {
    if s.is_empty() || s.len() > 128 || s.chars().any(char::is_control) {
        Err("identifiers must be 1..=128 bytes without control characters".into())
    } else {
        Ok(())
    }
}

pub fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    let s = v
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing or invalid {key}"))?;
    identifier(s)?;
    Ok(s)
}

pub fn number(v: &Value, key: &str) -> Result<f64> {
    v.get(key)
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite())
        .ok_or_else(|| format!("missing or non-finite numeric {key}"))
}

pub fn version(v: &Value, key: &str) -> Result<u64> {
    v.get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("missing or invalid unsigned integer {key}"))
}

pub fn timestamp(s: &str) -> Result<i64> {
    let t = time::OffsetDateTime::parse(s, &time::format_description::well_known::Rfc3339)
        .map_err(|_| "timestamp must be RFC3339 with timezone".to_owned())?;
    if t.nanosecond() % 1_000_000 != 0 {
        return Err("timestamp precision must be milliseconds or coarser".into());
    }
    i64::try_from(t.unix_timestamp_nanos() / 1_000_000).map_err(|_| "timestamp out of range".into())
}

pub fn diagnostic(code: &str, asset: &str, detail: &str) -> Value {
    json!({"kind":"diagnostic","code":code,"assetId":asset,"detail":detail})
}

pub fn pending_output() -> Value {
    json!({"kind":"pending"})
}

// SDK Map emits exactly once per input. Batch envelopes prevent losing finalized
// records when a tick or one later event releases several buffered readings.
pub fn pack(mut records: Vec<Value>) -> Value {
    match records.len() {
        0 => pending_output(),
        1 => records.remove(0),
        _ => json!({"kind":"batch","records":records}),
    }
}
