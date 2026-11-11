// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub type Result<T> = std::result::Result<T, String>;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub role: Role,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "deserialize_input_topics"
    )]
    pub input_topics: Option<std::collections::BTreeMap<String, String>>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deadband: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heartbeat_interval_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub high: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub low: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raise_for_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clear_for_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_observation_gap_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alpha: Option<f64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub initial_states: Vec<InitialState>,
}

fn deserialize_input_topics<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<std::collections::BTreeMap<String, String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    struct Topics;
    impl<'de> serde::de::Visitor<'de> for Topics {
        type Value = Option<std::collections::BTreeMap<String, String>>;

        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("an object mapping unique input kinds to full MQTT topic strings")
        }

        fn visit_map<M>(self, mut map: M) -> std::result::Result<Self::Value, M::Error>
        where
            M: serde::de::MapAccess<'de>,
        {
            let mut topics = std::collections::BTreeMap::new();
            while let Some((kind, topic)) = map.next_entry::<String, String>()? {
                if topics.insert(kind, topic).is_some() {
                    return Err(serde::de::Error::custom("duplicate inputTopics kind"));
                }
            }
            Ok(Some(topics))
        }
    }
    deserializer.deserialize_map(Topics)
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
    ReportByException,
    StableAlarm,
    OfflineDetection,
    RunningTotal,
    SmoothReadings,
}

impl Role {
    pub(crate) fn input_kinds(self) -> &'static [&'static str] {
        match self {
            Self::ReportByException | Self::StableAlarm => &["reading", "tick"],
            Self::OfflineDetection => &["reading", "tick", "register"],
            Self::RunningTotal => &["reading", "reset"],
            Self::SmoothReadings => &["reading"],
            _ => &[],
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InitialState {
    pub asset_id: String,
    pub total: f64,
    pub state_version: u64,
    pub epoch: u64,
    pub last_sequence: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_sampled_at: Option<String>,
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
        let supplied: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        if supplied.get("inputTopics").is_some_and(Value::is_null) {
            return Err("inputTopics must not be null".into());
        }
        if let Some(topics) = &c.input_topics {
            let kinds = c.role.input_kinds();
            if kinds.is_empty()
                || topics.len() != kinds.len()
                || kinds.iter().any(|kind| !topics.contains_key(*kind))
            {
                return Err(
                    "inputTopics must contain exactly the input kinds for this role".into(),
                );
            }
            let mut unique = std::collections::BTreeSet::new();
            for topic in topics.values() {
                if topic.is_empty()
                    || topic.len() > 65_535
                    || topic
                        .chars()
                        .any(|ch| ch.is_control() || ch == '+' || ch == '#')
                    || !unique.insert(topic)
                {
                    return Err("inputTopics requires distinct, literal MQTT topics without wildcards or control characters".into());
                }
            }
        }
        for field in [
            "deadband",
            "heartbeatIntervalMs",
            "high",
            "low",
            "raiseForMs",
            "clearForMs",
            "maxObservationGapMs",
            "timeoutMs",
            "alpha",
        ] {
            if supplied.get(field).is_some_and(Value::is_null) {
                return Err(format!("{field} must not be null"));
            }
        }
        if supplied.get("initialStates").is_some() && c.role != Role::RunningTotal {
            return Err("initialStates is only valid for running-total".into());
        }
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
        let generic = matches!(
            c.role,
            Role::ReportByException
                | Role::StableAlarm
                | Role::OfflineDetection
                | Role::RunningTotal
                | Role::SmoothReadings
        );
        if generic && c.max_assets > 128 {
            return Err("maxAssets for reading patterns must be in 1..=128".into());
        }
        for (name, present, role) in [
            ("deadband", c.deadband.is_some(), Role::ReportByException),
            (
                "heartbeatIntervalMs",
                c.heartbeat_interval_ms.is_some(),
                Role::ReportByException,
            ),
            ("high", c.high.is_some(), Role::StableAlarm),
            ("low", c.low.is_some(), Role::StableAlarm),
            ("raiseForMs", c.raise_for_ms.is_some(), Role::StableAlarm),
            ("clearForMs", c.clear_for_ms.is_some(), Role::StableAlarm),
            (
                "maxObservationGapMs",
                c.max_observation_gap_ms.is_some(),
                Role::StableAlarm,
            ),
            ("timeoutMs", c.timeout_ms.is_some(), Role::OfflineDetection),
            ("alpha", c.alpha.is_some(), Role::SmoothReadings),
            (
                "initialStates",
                !c.initial_states.is_empty(),
                Role::RunningTotal,
            ),
        ] {
            if present && c.role != role {
                return Err(format!("{name} is not valid for this role"));
            }
        }
        if c.deadband.is_some_and(|v| !v.is_finite() || v <= 0.0) {
            return Err("deadband must be finite and >0".into());
        }
        if !c.high.unwrap_or(80.0).is_finite()
            || !c.low.unwrap_or(70.0).is_finite()
            || c.low.unwrap_or(70.0) >= c.high.unwrap_or(80.0)
        {
            return Err("low and high must be finite with low < high".into());
        }
        if c.alpha
            .is_some_and(|v| !v.is_finite() || v <= 0.0 || v > 1.0)
        {
            return Err("alpha must be in (0,1]".into());
        }
        for (name, value, min) in [
            ("heartbeatIntervalMs", c.heartbeat_interval_ms, 1),
            ("raiseForMs", c.raise_for_ms, 0),
            ("clearForMs", c.clear_for_ms, 0),
            ("maxObservationGapMs", c.max_observation_gap_ms, 1),
            ("timeoutMs", c.timeout_ms, 1),
        ] {
            if value.is_some_and(|v| v < min || v > 86_400_000) {
                return Err(format!("{name} must be in {min}..=86400000"));
            }
        }
        if c.initial_states.len() > c.max_assets {
            return Err("too many initialStates".into());
        }
        let mut ids = std::collections::BTreeSet::new();
        for s in &c.initial_states {
            identifier(&s.asset_id)?;
            if !ids.insert(&s.asset_id) || !s.total.is_finite() {
                return Err("initialStates require unique assetId and finite total".into());
            }
            if let Some(sampled_at) = &s.last_sampled_at {
                if timestamp(sampled_at)? < 0 {
                    return Err("lastSampledAt must be Unix epoch or later".into());
                }
            }
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
