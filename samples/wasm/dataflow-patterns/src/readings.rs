// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use std::collections::{BTreeMap, VecDeque};

use serde_json::{json, Value};

use crate::common::{
    diagnostic, number, pack, pending_output, string, timestamp, version, Config, Result, Role,
};

#[derive(Clone, Default)]
struct RecentPayloads {
    payloads: BTreeMap<String, Value>,
    order: VecDeque<String>,
}

impl RecentPayloads {
    fn get(&self, id: &str) -> Option<&Value> {
        self.payloads.get(id)
    }

    fn retain(&mut self, id: String, payload: Value, limit: usize) {
        // Call only after validation and state arithmetic succeed. The sequence
        // watermark rejects old inputs even after their payloads are forgotten.
        while self.order.len() >= limit {
            let oldest = self.order.pop_front().expect("positive history limit");
            self.payloads.remove(&oldest);
        }
        self.order.push_back(id.clone());
        self.payloads.insert(id, payload);
    }
}

#[derive(Clone, Default)]
struct Asset {
    readings: RecentPayloads,
    resets: RecentPayloads,
    sequence: Option<u64>,
    sampled_at: Option<i64>,
    sampled_at_text: Option<String>,
    reading: Option<Value>,
    received_at: u64,
    reported_at: Option<u64>,
    reported_value: f64,
    smoothed: Option<f64>,
    active: bool,
    pending_since: Option<u64>,
    offline: bool,
    total: f64,
    state_version: u64,
    epoch: u64,
}

/// Per-instance volatile state. No timer runs between input arrivals.
pub(crate) struct Readings {
    config: Config,
    assets: BTreeMap<String, Asset>,
}

impl Readings {
    pub(crate) fn new(config: Config) -> Self {
        let assets = config
            .initial_states
            .iter()
            .map(|s| {
                (
                    s.asset_id.clone(),
                    Asset {
                        total: s.total,
                        state_version: s.state_version,
                        epoch: s.epoch,
                        sequence: Some(s.last_sequence),
                        sampled_at: s
                            .last_sampled_at
                            .as_ref()
                            .map(|t| timestamp(t).expect("validated bootstrap")),
                        sampled_at_text: s.last_sampled_at.clone(),
                        ..Asset::default()
                    },
                )
            })
            .collect();
        Self { config, assets }
    }

    pub(crate) fn process(&mut self, input: Value, now: u64) -> Result<Value> {
        let kind = string(&input, "kind")?;
        let id = string(&input, "assetId")?.to_owned();
        let sampled_at = if input.get("sampledAt").is_some() {
            let time = timestamp(string(&input, "sampledAt")?)?;
            if time < 0
                || u128::from(time as u64)
                    > u128::from(now) + u128::from(self.config.max_future_skew_ms)
            {
                return Err("sampledAt must be nonnegative and within maxFutureSkewMs".into());
            }
            Some(time)
        } else {
            None
        };
        for field in [
            "smoothedValue",
            "total",
            "stateVersion",
            "lastSequence",
            "lastSampledAt",
            "reason",
            "state",
            "threshold",
            "emittedAtMs",
            "receivedAtMs",
            "observationAgeMs",
            "isFreshMeasurement",
            "lastSeenAtMs",
            "elapsedMs",
        ] {
            if input.get(field).is_some() {
                return Err(format!("input contains reserved output field {field}"));
            }
        }
        match kind {
            "tick" => {
                let Some(asset) = self.assets.get_mut(&id) else {
                    return Ok(pending_output());
                };
                Self::tick(&self.config, asset, &id, now)
            }
            "register" if self.config.role == Role::OfflineDetection => {
                if self.assets.contains_key(&id) {
                    return Ok(pending_output());
                }
                if self.assets.len() >= self.config.max_assets {
                    return Ok(capacity(&id));
                }
                self.assets.insert(
                    id,
                    Asset {
                        received_at: now,
                        ..Asset::default()
                    },
                );
                Ok(pending_output())
            }
            "reset" if self.config.role == Role::RunningTotal => self.reset(input, &id, now),
            "reading" => self.reading(input, &id, sampled_at, now),
            _ => Err(format!("unsupported reading pattern kind: {kind}")),
        }
    }

    fn reading(
        &mut self,
        input: Value,
        id: &str,
        sampled_at: Option<i64>,
        now: u64,
    ) -> Result<Value> {
        let message_id = string(&input, "messageId")?.to_owned();
        let sequence = version(&input, "sequence")?;
        let value = number(&input, "value")?;
        let epoch = if self.config.role == Role::RunningTotal {
            Some(version(&input, "epoch")?)
        } else {
            None
        };
        let existing = self.assets.get(id);
        if let Some(original) = existing.and_then(|s| s.readings.get(&message_id)) {
            return Ok(diagnostic(
                if original == &input {
                    "duplicate"
                } else {
                    "conflict"
                },
                id,
                "messageId is already retained; no state changed",
            ));
        }
        if self.config.role == Role::RunningTotal && existing.is_none() {
            return Ok(diagnostic(
                "uninitializedAsset",
                id,
                "provide externally durable initialStates before readings",
            ));
        }
        if existing.is_some_and(|s| {
            s.sequence.is_some_and(|v| sequence <= v)
                || sampled_at
                    .zip(s.sampled_at)
                    .is_some_and(|(new, old)| new < old)
        }) {
            return Ok(diagnostic(
                "staleReading",
                id,
                "sequence or sampledAt is older than accepted state",
            ));
        }
        if epoch.is_some_and(|epoch| existing.is_some_and(|s| s.epoch != epoch)) {
            return Ok(diagnostic(
                "epochConflict",
                id,
                "reading epoch does not match active total epoch",
            ));
        }
        if existing.is_none() && self.assets.len() >= self.config.max_assets {
            return Ok(capacity(id));
        }
        // Stage the bounded asset so numeric errors cannot consume IDs or mutate state.
        let mut asset = existing.cloned().unwrap_or_default();
        let mut outputs = Vec::new();
        let old_age = now - asset.received_at;
        if self.config.role == Role::OfflineDetection && existing.is_some() {
            if let Some(output) = offline(&self.config, &mut asset, id, now) {
                outputs.push(output);
            }
        }
        if self.config.role == Role::StableAlarm
            && asset.reading.is_some()
            && old_age > self.config.max_observation_gap_ms.unwrap_or(5_000)
        {
            asset.pending_since = None;
        }
        let had_reading = asset.reading.is_some();
        asset.reading = Some(input.clone());
        asset.received_at = now;
        if let Some(sampled_at) = sampled_at {
            asset.sampled_at = Some(sampled_at);
            asset.sampled_at_text = Some(string(&input, "sampledAt")?.to_owned());
        }
        match self.config.role {
            Role::ReportByException => {
                let reason = if asset.reported_at.is_none() {
                    Some("initial")
                } else if changed(
                    value,
                    asset.reported_value,
                    self.config.deadband.unwrap_or(1.0),
                ) {
                    Some("change")
                } else {
                    None
                };
                if let Some(reason) = reason {
                    outputs.push(report(&mut asset, now, reason));
                }
            }
            Role::SmoothReadings => {
                let alpha = self.config.alpha.unwrap_or(0.5);
                let smoothed = asset
                    .smoothed
                    .map_or(value, |previous| alpha * value + (1.0 - alpha) * previous);
                if !smoothed.is_finite() {
                    return Err("smoothing arithmetic overflow".into());
                }
                asset.smoothed = Some(smoothed);
                let mut output = output_reading(&asset, "smoothed", now);
                output["smoothedValue"] = json!(smoothed);
                outputs.push(output);
            }
            Role::StableAlarm => {
                if let Some(output) = alarm(&self.config, &mut asset, now, true) {
                    outputs.push(output);
                }
            }
            Role::OfflineDetection => {
                if !had_reading || asset.offline {
                    outputs.push(json!({
                        "kind":"availability", "assetId":id, "state":"online",
                        "reason":if asset.offline { "recovered" } else { "firstReading" },
                        "emittedAtMs":now, "lastSeenAtMs":now,
                        "elapsedMs":if asset.offline { old_age } else { 0 }
                    }));
                }
                asset.offline = false;
            }
            Role::RunningTotal => {
                let total = asset.total + value;
                if !total.is_finite() {
                    return Err("running total arithmetic overflow".into());
                }
                asset.state_version = asset
                    .state_version
                    .checked_add(1)
                    .ok_or("stateVersion overflow")?;
                asset.total = total;
                let mut output = output_reading(&asset, "total", now);
                output["total"] = json!(total);
                output["stateVersion"] = json!(asset.state_version);
                output["epoch"] = json!(asset.epoch);
                output["lastSequence"] = json!(sequence);
                if let Some(time) = &asset.sampled_at_text {
                    output["lastSampledAt"] = json!(time);
                }
                outputs.push(output);
            }
            _ => unreachable!("reading pattern configuration"),
        }
        asset.sequence = Some(sequence);
        asset
            .readings
            .retain(message_id, input, self.config.max_history_per_asset);
        self.assets.insert(id.to_owned(), asset);
        Ok(pack(outputs))
    }

    fn reset(&mut self, input: Value, id: &str, now: u64) -> Result<Value> {
        if input.get("epoch").is_some() {
            return Err("reset contains reserved output field epoch".into());
        }
        let reset_id = string(&input, "resetId")?.to_owned();
        let sequence = version(&input, "sequence")?;
        let expected = version(&input, "expectedStateVersion")?;
        let Some(asset) = self.assets.get_mut(id) else {
            return Ok(diagnostic(
                "uninitializedAsset",
                id,
                "provide initialStates before reset",
            ));
        };
        if let Some(original) = asset.resets.get(&reset_id) {
            return Ok(diagnostic(
                if original == &input {
                    "duplicateReset"
                } else {
                    "conflictReset"
                },
                id,
                "resetId already retained; no state changed",
            ));
        }
        if expected != asset.state_version {
            return Ok(diagnostic(
                "versionConflict",
                id,
                "expectedStateVersion does not match",
            ));
        }
        if asset.sequence.is_some_and(|previous| sequence <= previous) {
            return Ok(diagnostic(
                "staleReading",
                id,
                "reset sequence must advance the watermark",
            ));
        }
        let state_version = asset
            .state_version
            .checked_add(1)
            .ok_or("stateVersion overflow")?;
        let epoch = asset.epoch.checked_add(1).ok_or("epoch overflow")?;
        let mut output = input.clone();
        output["kind"] = json!("totalReset");
        output["total"] = json!(0.0);
        output["stateVersion"] = json!(state_version);
        output["epoch"] = json!(epoch);
        output["lastSequence"] = json!(sequence);
        output["emittedAtMs"] = json!(now);
        if let Some(time) = &asset.sampled_at_text {
            output["lastSampledAt"] = json!(time);
        }
        asset.total = 0.0;
        asset.state_version = state_version;
        asset.epoch = epoch;
        asset.sequence = Some(sequence);
        asset
            .resets
            .retain(reset_id, input, self.config.max_updates_per_asset);
        Ok(output)
    }

    fn tick(config: &Config, asset: &mut Asset, id: &str, now: u64) -> Result<Value> {
        Ok(match config.role {
            Role::ReportByException => {
                if config.heartbeat_interval_ms.is_some_and(|interval| {
                    asset.reported_at.is_some_and(|last| now - last >= interval)
                }) {
                    report(asset, now, "heartbeat")
                } else {
                    pending_output()
                }
            }
            Role::StableAlarm => alarm(config, asset, now, false).unwrap_or_else(pending_output),
            Role::OfflineDetection => {
                offline(config, asset, id, now).unwrap_or_else(pending_output)
            }
            _ => pending_output(),
        })
    }
}

fn capacity(id: &str) -> Value {
    diagnostic(
        "capacity",
        id,
        "configured capacity reached; no state or dedup history was evicted",
    )
}

fn changed(value: f64, previous: f64, deadband: f64) -> bool {
    // Infinite subtraction of finite endpoints still means a finite threshold was crossed.
    (value - previous).abs() >= deadband
}

fn output_reading(asset: &Asset, kind: &str, now: u64) -> Value {
    let mut output = asset.reading.clone().expect("accepted observation");
    output["kind"] = json!(kind);
    output["emittedAtMs"] = json!(now);
    output
}

fn observation(output: &mut Value, asset: &Asset, now: u64, fresh: bool) {
    output["receivedAtMs"] = json!(asset.received_at);
    output["observationAgeMs"] = json!(now - asset.received_at);
    output["isFreshMeasurement"] = json!(fresh);
}

fn report(asset: &mut Asset, now: u64, reason: &str) -> Value {
    let mut output = output_reading(asset, "reported", now);
    output["reason"] = json!(reason);
    observation(&mut output, asset, now, reason != "heartbeat");
    asset.reported_at = Some(now);
    asset.reported_value = output["value"].as_f64().expect("finite observation");
    output
}

fn alarm(config: &Config, asset: &mut Asset, now: u64, fresh: bool) -> Option<Value> {
    let reading = asset.reading.as_ref()?;
    if now - asset.received_at > config.max_observation_gap_ms.unwrap_or(5_000) {
        asset.pending_since = None;
        return None;
    }
    let value = reading["value"].as_f64().expect("finite observation");
    let (threshold, qualifies, duration) = if asset.active {
        let threshold = config.low.unwrap_or(70.0);
        (
            threshold,
            value <= threshold,
            config.clear_for_ms.unwrap_or(0),
        )
    } else {
        let threshold = config.high.unwrap_or(80.0);
        (
            threshold,
            value >= threshold,
            config.raise_for_ms.unwrap_or(0),
        )
    };
    if !qualifies {
        asset.pending_since = None;
        return None;
    }
    let since = *asset.pending_since.get_or_insert(now);
    if now - since < duration {
        return None;
    }
    asset.active = !asset.active;
    asset.pending_since = None;
    let mut output = output_reading(asset, "alarm", now);
    output["state"] = json!(if asset.active { "active" } else { "cleared" });
    output["reason"] = json!("thresholdSustained");
    output["threshold"] = json!(threshold);
    observation(&mut output, asset, now, fresh);
    Some(output)
}

fn offline(config: &Config, asset: &mut Asset, id: &str, now: u64) -> Option<Value> {
    let elapsed = now - asset.received_at;
    if asset.offline || elapsed < config.timeout_ms.unwrap_or(10_000) {
        return None;
    }
    asset.offline = true;
    Some(json!({
        "kind":"availability", "assetId":id, "state":"offline", "reason":"timeout",
        "emittedAtMs":now,
        "lastSeenAtMs":asset.reading.as_ref().map(|_| asset.received_at),
        "elapsedMs":elapsed
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recent_payload_storage_remains_bounded_and_tracks_acceptance_order() {
        for limit in [1, 2, 256, 512] {
            let mut history = RecentPayloads::default();
            for n in 0..limit * 11 {
                history.retain(format!("id-{n}"), json!({"sequence":n}), limit);
                assert_eq!(history.payloads.len(), limit.min(n + 1));
                assert_eq!(history.order.len(), history.payloads.len());
                assert!(history
                    .order
                    .iter()
                    .all(|id| history.payloads.contains_key(id)));
                if n >= limit {
                    assert!(history.get(&format!("id-{}", n - limit)).is_none());
                }
            }
        }
    }
}
