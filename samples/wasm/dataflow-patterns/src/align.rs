// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use crate::common::{diagnostic, number, pack, string, timestamp, Config, Result};
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Key(i64, Option<String>, Option<String>);

struct Reading {
    value: Value,
    since: u64,
}
struct Context {
    value: Value,
    temperature: f64,
}
struct Completed {
    value: Value,
    since: u64,
}

#[derive(Default)]
struct Asset {
    high_time: Option<i64>,
    history: BTreeMap<i64, Context>,
    pending: BTreeMap<Key, Reading>,
    completed: BTreeMap<Key, Completed>,
    last_activity: u64,
}

/// Event-time watermark plus a processing-time deadline, evaluated on arrivals.
/// Idle streams require a periodic tick; Map cannot autonomously emit a timer.
pub struct Aligner {
    config: Config,
    assets: BTreeMap<String, Asset>,
}

impl Aligner {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            assets: BTreeMap::new(),
        }
    }

    pub fn process(&mut self, input: Value, now_ms: u64) -> Result<Value> {
        let kind = string(&input, "kind")?;
        if !["speed", "temperature", "tick"].contains(&kind) {
            return Err(format!("unsupported aligner kind: {kind}"));
        }
        let asset_id = string(&input, "assetId")?.to_owned();
        let sampled = timestamp(string(&input, "sampledAt")?)?;
        if sampled < 0 {
            return Err("sampledAt must not precede Unix epoch".into());
        }
        if sampled as u64 > now_ms.saturating_add(self.config.max_future_skew_ms) {
            return Err("sampledAt exceeds maxFutureSkewMs relative to processing clock".into());
        }
        for field in ["pieceId", "runId"] {
            if input.get(field).is_some() {
                string(&input, field)?;
            }
        }
        if kind == "temperature" {
            number(&input, "temperature")?;
        }
        if kind == "speed" {
            number(&input, "speed")?;
            for field in ["temperature", "temperatureSampledAt"] {
                if input.get(field).is_some() {
                    return Err(format!("speed contains reserved output field {field}"));
                }
            }
        }
        let key = Key(
            sampled,
            input
                .get("pieceId")
                .and_then(Value::as_str)
                .map(str::to_owned),
            input
                .get("runId")
                .and_then(Value::as_str)
                .map(str::to_owned),
        );
        let mut records = Vec::new();
        self.assets.retain(|_, state| {
            state
                .completed
                .retain(|_, c| now_ms.saturating_sub(c.since) < self.config.completed_ttl_ms);
            !state.pending.is_empty()
                || !state.completed.is_empty()
                || now_ms.saturating_sub(state.last_activity) < self.config.pending_ttl_ms
        });
        // Do not finalize processing deadlines before considering this arrival's
        // context. Watermark violations below still reject genuinely late data.
        if !self.assets.contains_key(&asset_id) {
            self.advance(now_ms, &mut records);
            if kind == "tick" {
                return Ok(pack(records));
            }
            if self.assets.len() >= self.config.max_assets {
                records.push(diagnostic(
                    "capacity",
                    &asset_id,
                    "maxAssets reached; no asset evicted",
                ));
                return Ok(pack(records));
            }
        }
        let state = self.assets.entry(asset_id.clone()).or_default();
        state.last_activity = now_ms;
        let watermark = state
            .high_time
            .map(|t| t - self.config.allowed_lateness_ms as i64);

        let duplicate = if kind == "speed" {
            state
                .pending
                .get(&key)
                .map(|r| &r.value)
                .or_else(|| state.completed.get(&key).map(|r| &r.value))
        } else if kind == "temperature" {
            state.history.get(&sampled).map(|c| &c.value)
        } else {
            None
        };
        if let Some(original) = duplicate {
            records.push(input_diagnostic(
                if original == &input {
                    "duplicate"
                } else {
                    "conflict"
                },
                &asset_id,
                &input,
                "event key already seen; original retained",
            ));
        } else if kind != "tick"
            && watermark.is_some_and(|w| {
                if kind == "temperature" {
                    sampled <= w
                } else {
                    sampled < w
                }
            })
        {
            records.push(input_diagnostic(
                "tooLate",
                &asset_id,
                &input,
                "event is behind the finalized watermark",
            ));
        } else if kind == "speed"
            && state.pending.len() + state.completed.len()
                >= self.config.max_pending_per_asset + self.config.max_completed_per_asset
        {
            records.push(input_diagnostic(
                "capacity",
                &asset_id,
                &input,
                "reading retention capacity reached",
            ));
        } else if kind == "speed" && state.pending.len() >= self.config.max_pending_per_asset {
            records.push(input_diagnostic(
                "capacity",
                &asset_id,
                &input,
                "maxPendingPerAsset reached",
            ));
        } else if kind == "temperature" && state.history.len() >= self.config.max_history_per_asset
        {
            records.push(input_diagnostic(
                "capacity",
                &asset_id,
                &input,
                "maxHistoryPerAsset reached; history not evicted",
            ));
        } else {
            state.high_time = Some(state.high_time.map_or(sampled, |t| t.max(sampled)));
            match kind {
                "temperature" => {
                    state.history.insert(
                        sampled,
                        Context {
                            temperature: number(&input, "temperature")?,
                            value: input,
                        },
                    );
                }
                "speed" => {
                    state.pending.insert(
                        key,
                        Reading {
                            value: input,
                            since: now_ms,
                        },
                    );
                }
                _ => {}
            }
        }
        self.advance(now_ms, &mut records);
        Ok(pack(records))
    }

    fn advance(&mut self, now_ms: u64, out: &mut Vec<Value>) {
        let config = &self.config;
        self.assets.retain(|asset_id, state| {
            state
                .completed
                .retain(|_, c| now_ms.saturating_sub(c.since) < config.completed_ttl_ms);
            let watermark = state
                .high_time
                .map(|t| t - config.allowed_lateness_ms as i64);
            let ready: Vec<Key> = state
                .pending
                .iter()
                .filter(|(key, reading)| {
                    watermark.is_some_and(|w| key.0 <= w)
                        || now_ms.saturating_sub(reading.since) >= config.allowed_lateness_ms
                })
                .map(|(key, _)| key.clone())
                .collect();
            for key in ready {
                // Keep ready readings pending if dedup capacity is exhausted.
                // At TTL emit an explicit rejection rather than silently evict.
                if state.completed.len() >= config.max_completed_per_asset {
                    if now_ms.saturating_sub(state.pending[&key].since) >= config.pending_ttl_ms {
                        let r = state.pending.remove(&key).expect("ready key exists");
                        out.push(input_diagnostic(
                            "expired",
                            asset_id,
                            &r.value,
                            "dedup capacity prevented finalization before pendingTtlMs",
                        ));
                    }
                    continue;
                }
                let reading = state.pending.remove(&key).expect("ready key exists");
                let result = state
                    .history
                    .range(..=key.0)
                    .next_back()
                    .filter(|(t, _)| key.0 - **t <= config.max_context_age_ms as i64);
                let output = if let Some((_, context)) = result {
                    let mut output = reading.value.clone();
                    let object = output.as_object_mut().expect("validated object");
                    object.remove("kind");
                    object.insert("temperature".into(), json!(context.temperature));
                    object.insert(
                        "temperatureSampledAt".into(),
                        context.value["sampledAt"].clone(),
                    );
                    output
                } else {
                    input_diagnostic(
                        "noContext",
                        asset_id,
                        &reading.value,
                        "no context at or before sampledAt within maxContextAgeMs",
                    )
                };
                out.push(output);
                state.completed.insert(
                    key,
                    Completed {
                        value: reading.value,
                        since: now_ms,
                    },
                );
            }
            if let Some(watermark) = watermark {
                // Retain sufficient history for both future and still-pending
                // readings, including those held by completed-capacity pressure.
                let oldest = state
                    .pending
                    .keys()
                    .next()
                    .map_or(watermark, |k| k.0.min(watermark));
                state
                    .history
                    .retain(|t, _| *t >= oldest - config.max_context_age_ms as i64);
            }
            !state.pending.is_empty()
                || !state.completed.is_empty()
                || now_ms.saturating_sub(state.last_activity) < config.pending_ttl_ms
        });
    }
}

fn input_diagnostic(code: &str, asset: &str, input: &Value, detail: &str) -> Value {
    let mut d = diagnostic(code, asset, detail);
    for field in ["sampledAt", "pieceId", "runId"] {
        if let Some(v) = input.get(field) {
            d[field] = v.clone();
        }
    }
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    fn align() -> Aligner {
        Aligner::new(Config::parse(r#"{"role":"align-by-time"}"#).unwrap())
    }
    fn event(kind: &str, second: u64, value: f64) -> Value {
        let mut v = json!({"kind":kind,"assetId":"line-1","sampledAt":format!("1970-01-01T00:00:{second:02}Z")});
        v[kind] = json!(value);
        v
    }
    fn tick(second: u64) -> Value {
        json!({"kind":"tick","assetId":"line-1","sampledAt":format!("1970-01-01T00:00:{second:02}Z")})
    }
    #[test]
    fn docs_selects_past_context_after_event_time_tick() {
        let mut a = align();
        assert_eq!(
            a.process(event("temperature", 1, 20.), 3000).unwrap()["kind"],
            "pending"
        );
        a.process(event("temperature", 3, 22.), 3000).unwrap();
        assert_eq!(
            a.process(event("speed", 2, 12.), 3000).unwrap()["kind"],
            "pending"
        );
        let out = a.process(tick(4), 4000).unwrap();
        assert_eq!(out["temperature"], 20.);
        assert_eq!(out["temperatureSampledAt"], "1970-01-01T00:00:01Z");
        assert_eq!(out["speed"], 12.);
    }
    #[test]
    fn processing_deadline_flushes_tail_only_on_an_arrival() {
        let mut a = align();
        a.process(event("speed", 2, 12.), 2000).unwrap();
        a.process(event("temperature", 1, 20.), 3000).unwrap();
        assert_eq!(a.process(tick(2), 3999).unwrap()["kind"], "pending");
        assert_eq!(a.process(tick(2), 4000).unwrap()["temperature"], 20.);
    }
    #[test]
    fn no_future_context_or_stale_context_and_age_is_inclusive() {
        for (context, expected) in [(1, Some(20.)), (0, None), (7, None)] {
            let mut a = align();
            a.process(event("temperature", context, 20.), 6000).unwrap();
            a.process(event("speed", 6, 12.), 6000).unwrap();
            let out = a.process(tick(8), 8000).unwrap();
            if let Some(t) = expected {
                assert_eq!(out["temperature"], t);
            } else {
                assert_eq!(out["code"], "noContext");
            }
        }
    }
    #[test]
    fn multiple_ready_records_are_batched_not_lost() {
        let mut a = align();
        a.process(event("temperature", 1, 20.), 1000).unwrap();
        a.process(event("speed", 2, 12.), 2000).unwrap();
        a.process(event("speed", 3, 13.), 3000).unwrap();
        let out = a.process(tick(5), 5000).unwrap();
        assert_eq!(out["kind"], "batch");
        assert_eq!(out["records"].as_array().unwrap().len(), 2);
    }
    #[test]
    fn late_context_cannot_revise_output() {
        let mut a = align();
        a.process(event("temperature", 1, 20.), 1000).unwrap();
        a.process(event("speed", 2, 12.), 2000).unwrap();
        a.process(tick(4), 4000).unwrap();
        assert_eq!(
            a.process(event("temperature", 2, 25.), 4000).unwrap()["code"],
            "tooLate"
        );
    }
    #[test]
    fn duplicate_conflict_and_pending_cleanup() {
        let mut a = align();
        let r = event("speed", 2, 12.);
        a.process(r.clone(), 2000).unwrap();
        assert_eq!(a.process(r.clone(), 2001).unwrap()["code"], "duplicate");
        assert_eq!(
            a.process(event("speed", 2, 13.), 2002).unwrap()["code"],
            "conflict"
        );
        a.process(tick(4), 4000).unwrap();
        assert!(a.assets["line-1"].pending.is_empty());
        assert_eq!(a.process(r, 4001).unwrap()["code"], "duplicate");
        a.process(tick(4), 100000).unwrap();
        assert!(!a.assets.contains_key("line-1"));
    }
    #[test]
    fn per_asset_isolation_and_limits() {
        let mut c = Config::parse(r#"{"role":"align-by-time","maxAssets":1,"maxHistoryPerAsset":1,"maxPendingPerAsset":1}"#).unwrap();
        c.allowed_lateness_ms = 2000;
        let mut a = Aligner::new(c);
        a.process(event("temperature", 1, 20.), 1000).unwrap();
        assert_eq!(
            a.process(event("temperature", 2, 21.), 2000).unwrap()["code"],
            "capacity"
        );
        a.process(event("speed", 2, 12.), 2000).unwrap();
        assert_eq!(
            a.process(event("speed", 3, 12.), 2001).unwrap()["code"],
            "capacity"
        );
        let mut other = event("speed", 2, 12.);
        other["assetId"] = json!("other");
        assert_eq!(a.process(other, 2002).unwrap()["code"], "capacity");
    }
    #[test]
    fn schema_clock_skew_invalid_numbers_and_reserved_fields() {
        let mut a = align();
        for input in [
            json!({}),
            json!({"kind":"humidity","assetId":"a","sampledAt":"bad"}),
            json!({"kind":"speed","assetId":"a","sampledAt":"1970-01-01T00:00:01Z","speed":"NaN"}),
            json!({"kind":"temperature","assetId":"a","sampledAt":"2026-10-20","temperature":1}),
        ] {
            assert!(a.process(input, 1000).is_err());
        }
        assert!(a.process(event("speed", 40, 12.), 1000).is_err());
        let mut bad = event("speed", 1, 12.);
        bad["temperature"] = json!(20);
        assert!(a.process(bad, 1000).is_err());
    }
    #[test]
    fn zero_lateness_and_distinct_piece_ids_at_same_timestamp() {
        let mut c = Config::parse(r#"{"role":"align-by-time","allowedLatenessMs":0}"#).unwrap();
        c.max_completed_per_asset = 2;
        let mut a = Aligner::new(c);
        a.process(event("temperature", 1, 20.), 1000).unwrap();
        for piece in ["p1", "p2"] {
            let mut r = event("speed", 2, 12.);
            r["pieceId"] = json!(piece);
            assert_eq!(a.process(r, 2000).unwrap()["temperature"], 20.);
        }
    }
}
