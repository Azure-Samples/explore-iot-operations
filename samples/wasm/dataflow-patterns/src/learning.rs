// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use std::collections::{BTreeMap, VecDeque};

use nalgebra::{linalg::SVD, DMatrix, DVector};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::common::{diagnostic, identifier, pending_output, timestamp, Config, Result, Role};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FitConfig {
    pub epoch: u64,
    pub feature_count: usize,
    pub min_samples: usize,
    pub max_samples: usize,
    pub lookback_ms: u64,
    pub max_condition: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecommendationConfig {
    pub epoch: u64,
    pub model_version: u64,
    pub gain: f64,
    pub min_value: f64,
    pub max_value: f64,
    pub max_step: f64,
    pub max_age_ms: u64,
}

pub(crate) fn validate_config(c: &Config) -> Result<()> {
    if c.fit.is_some() != (c.role == Role::FitLinearModel)
        || c.recommendation.is_some() != (c.role == Role::BoundedRecommendation)
    {
        return Err(
            "fit/recommendation settings are required only for their respective role".into(),
        );
    }
    if matches!(c.role, Role::FitLinearModel | Role::BoundedRecommendation) && c.max_assets > 128 {
        return Err("learning roles require maxAssets in 1..=128".into());
    }
    if let Some(f) = &c.fit {
        if f.epoch == 0
            || !(1..=8).contains(&f.feature_count)
            || f.min_samples < f.feature_count + 1
            || f.min_samples > f.max_samples
            || f.max_samples > 1024
            || !(1..=86_400_000).contains(&f.lookback_ms)
            || !f.max_condition.is_finite()
            || !(1.0..=1e8).contains(&f.max_condition)
        {
            return Err(
                "invalid fit epoch, dimensions, sample/lookback bounds or condition limit".into(),
            );
        }
    }
    if let Some(r) = &c.recommendation {
        if r.epoch == 0
            || r.model_version == 0
            || ![r.gain, r.min_value, r.max_value, r.max_step]
                .iter()
                .all(|v| v.is_finite() && v.abs() <= 1e100)
            || r.min_value >= r.max_value
            || r.max_step <= 0.0
            || !(1..=86_400_000).contains(&r.max_age_ms)
        {
            return Err(
                "invalid recommendation epoch, model version, bounds, gain or freshness".into(),
            );
        }
    }
    Ok(())
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Sample {
    kind: String,
    asset_id: String,
    sample_id: String,
    epoch: u64,
    sequence: u64,
    model_version: u64,
    sampled_at: String,
    features: Vec<f64>,
    target: f64,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Decision {
    kind: String,
    asset_id: String,
    decision_id: String,
    epoch: u64,
    sequence: u64,
    model_version: u64,
    sampled_at: String,
    current_value: f64,
    error: f64,
}

#[derive(Clone)]
struct Row {
    sample: Sample,
    time: u64,
}

#[derive(Default, Clone)]
struct Training {
    rows: VecDeque<Row>,
    last_sequence: Option<u64>,
    last_time: u64,
    basis: u64,
}

struct PreviousDecision {
    input: Decision,
    time: u64,
}

pub struct Learning {
    config: Config,
    training: BTreeMap<String, Training>,
    decisions: BTreeMap<String, PreviousDecision>,
}

fn finite(value: f64) -> bool {
    value.is_finite() && value.abs() <= 1e100
}

fn event_time(text: &str, now: u64, max_age: u64) -> Result<u64> {
    let time = u64::try_from(timestamp(text)?).map_err(|_| "timestamp precedes Unix epoch")?;
    if time > now || now - time > max_age {
        return Err(
            "sampledAt must not be future or older than the configured lookback/age".into(),
        );
    }
    Ok(time)
}

impl Learning {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            training: BTreeMap::new(),
            decisions: BTreeMap::new(),
        }
    }

    pub fn process(&mut self, input: Value, now: u64) -> Result<Value> {
        match self.config.role {
            Role::FitLinearModel => self.sample(input, now),
            Role::BoundedRecommendation => self.decision(input, now),
            _ => Err("unsupported learning role".into()),
        }
    }

    fn sample(&mut self, input: Value, now: u64) -> Result<Value> {
        let s: Sample = serde_json::from_value(input).map_err(|e| e.to_string())?;
        let f = self.config.fit.as_ref().expect("validated fit");
        identifier(&s.asset_id)?;
        identifier(&s.sample_id)?;
        if s.kind != "sample"
            || s.epoch != f.epoch
            || s.model_version == 0
            || s.features.len() != f.feature_count
            || !s.features.iter().copied().chain([s.target]).all(finite)
        {
            return Err(
                "invalid sample kind, epoch, model version, dimensions or numeric range".into(),
            );
        }
        let time = event_time(&s.sampled_at, now, f.lookback_ms)?;
        let existing = self.training.get(&s.asset_id);
        if let Some(t) = existing {
            if let Some(original) = t.rows.iter().find(|r| r.sample.sample_id == s.sample_id) {
                return Ok(diagnostic(
                    if original.sample == s {
                        "duplicateSample"
                    } else {
                        "conflictingSample"
                    },
                    &s.asset_id,
                    "sampleId is retained; no training or freshness change",
                ));
            }
            if t.last_sequence.is_some_and(|last| s.sequence <= last)
                || time < t.last_time
                || s.model_version != t.basis
            {
                return Err("sample sequence/time regressed or basis model version changed; start a new epoch".into());
            }
        } else if self.training.len() >= self.config.max_assets {
            return Err("maxAssets reached; no assets are evicted".into());
        }
        // Compute on bounded scratch state so numerical failures never consume an input.
        let mut t = existing.cloned().unwrap_or_default();
        while t.rows.front().is_some_and(|r| now - r.time > f.lookback_ms) {
            t.rows.pop_front();
        }
        if t.rows.len() == f.max_samples {
            t.rows.pop_front();
        }
        t.rows.push_back(Row {
            sample: s.clone(),
            time,
        });
        t.last_sequence = Some(s.sequence);
        t.last_time = time;
        t.basis = s.model_version;
        let output = if t.rows.len() < f.min_samples {
            pending_output()
        } else {
            fit(&t.rows, f, &s, now)?
        };
        self.training.insert(s.asset_id.clone(), t);
        Ok(output)
    }

    fn decision(&mut self, input: Value, now: u64) -> Result<Value> {
        let d: Decision = serde_json::from_value(input).map_err(|e| e.to_string())?;
        let c = self
            .config
            .recommendation
            .as_ref()
            .expect("validated recommendation");
        identifier(&d.asset_id)?;
        identifier(&d.decision_id)?;
        if d.kind != "decision"
            || d.epoch != c.epoch
            || d.model_version != c.model_version
            || ![d.current_value, d.error].into_iter().all(finite)
            || !(c.min_value..=c.max_value).contains(&d.current_value)
        {
            return Err(
                "invalid decision kind, epoch, model version, numeric range or current value"
                    .into(),
            );
        }
        let time = event_time(&d.sampled_at, now, c.max_age_ms)?;
        if let Some(previous) = self.decisions.get(&d.asset_id) {
            if d.decision_id == previous.input.decision_id {
                return Ok(diagnostic(
                    if d == previous.input {
                        "duplicateDecision"
                    } else {
                        "conflictingDecision"
                    },
                    &d.asset_id,
                    "last decisionId retained; no recommendation emitted",
                ));
            }
            if d.sequence <= previous.input.sequence || time < previous.time {
                return Err("decision sequence or sampledAt regressed".into());
            }
        } else if self.decisions.len() >= self.config.max_assets {
            return Err("maxAssets reached; no assets are evicted".into());
        }
        let raw = c.gain * d.error;
        let step = raw.clamp(-c.max_step, c.max_step);
        let value = (d.current_value + step).clamp(c.min_value, c.max_value);
        let delta = value - d.current_value;
        if ![raw, step, value, delta].iter().all(|v| v.is_finite()) || delta.abs() > c.max_step {
            return Err(
                "recommendation arithmetic overflow or representable delta exceeds maxStep".into(),
            );
        }
        let output = json!({
            "kind":"recommendation", "assetId":d.asset_id, "decisionId":d.decision_id,
            "epoch":d.epoch, "sequence":d.sequence, "modelVersion":d.model_version,
            "sampledAt":d.sampled_at, "evaluatedAtMs":now, "currentValue":d.current_value,
            "error":d.error, "recommendedValue":value, "delta":delta,
            "limited":delta != raw,
            "approved":false, "actuation":false
        });
        self.decisions
            .insert(d.asset_id.clone(), PreviousDecision { input: d, time });
        Ok(output)
    }
}

fn root_mean_square(values: impl Iterator<Item = f64>) -> f64 {
    let values: Vec<_> = values.collect();
    if values.iter().any(|v| !v.is_finite()) {
        return f64::INFINITY;
    }
    let scale = values.iter().map(|v| v.abs()).fold(0.0, f64::max);
    if scale == 0.0 {
        return 0.0;
    }
    let rms = scale
        * (values.iter().map(|v| (v / scale).powi(2)).sum::<f64>() / values.len() as f64).sqrt();
    if rms == 0.0 {
        f64::INFINITY
    } else {
        rms
    }
}

fn fit(rows: &VecDeque<Row>, c: &FitConfig, latest: &Sample, now: u64) -> Result<Value> {
    let n = rows.len();
    let p = c.feature_count;
    let mut means = vec![0.0; p];
    let mut scales = vec![0.0; p];
    for j in 0..p {
        let anchor = rows[0].sample.features[j];
        means[j] = anchor
            + rows
                .iter()
                .map(|r| (r.sample.features[j] - anchor) / n as f64)
                .sum::<f64>();
        scales[j] = root_mean_square(rows.iter().map(|r| r.sample.features[j] - means[j]));
        if !scales[j].is_finite() {
            return Err("feature scale is not representable; input not consumed".into());
        }
        if scales[j] == 0.0 {
            return Ok(diagnostic(
                "rankDeficient",
                &latest.asset_id,
                "constant feature; candidate withheld",
            ));
        }
    }
    let a = DMatrix::from_fn(n, p + 1, |i, j| {
        if j == p {
            1.0
        } else {
            (rows[i].sample.features[j] - means[j]) / scales[j]
        }
    });
    // Normalize targets before averaging/solving, including representable subnormals.
    let target_scale = rows
        .iter()
        .map(|r| r.sample.target.abs())
        .fold(0.0, f64::max);
    let target_scale = if target_scale == 0.0 {
        1.0
    } else {
        target_scale
    };
    let anchor_y = rows[0].sample.target / target_scale;
    let mean_y_normalized = anchor_y
        + rows
            .iter()
            .map(|r| (r.sample.target / target_scale - anchor_y) / n as f64)
            .sum::<f64>();
    let mean_y = mean_y_normalized * target_scale;
    let y = DVector::from_iterator(
        n,
        rows.iter()
            .map(|r| r.sample.target / target_scale - mean_y_normalized),
    );
    // Standardized design and bounded SVD iterations avoid normal-equation conditioning.
    let svd = SVD::try_new(a, true, true, f64::EPSILON, 1000)
        .ok_or("SVD did not converge; input not consumed")?;
    let largest = svd.singular_values.max();
    let smallest = svd.singular_values.min();
    let condition = largest / smallest;
    if !condition.is_finite() || smallest <= largest / c.max_condition {
        return Ok(diagnostic(
            "rankDeficient",
            &latest.asset_id,
            "design rank/conditioning limit; candidate withheld",
        ));
    }
    let solution = svd
        .solve(&y, largest / c.max_condition)
        .map_err(str::to_owned)?;
    let coefficients: Vec<f64> = (0..p)
        .map(|j| {
            if solution[j] == 0.0 {
                return Ok(0.0);
            }
            let ratio = target_scale / scales[j];
            let coefficient = solution[j] * ratio;
            if ratio == 0.0 || !ratio.is_finite() || coefficient == 0.0 || !coefficient.is_finite()
            {
                return Err(
                    "coefficient scaling is not representable; input not consumed".to_owned(),
                );
            }
            Ok(coefficient)
        })
        .collect::<Result<_>>()?;
    let intercept = (mean_y_normalized + solution[p]) * target_scale
        - (0..p).map(|j| coefficients[j] * means[j]).sum::<f64>();
    let predictions: Vec<f64> = rows
        .iter()
        .map(|r| {
            intercept
                + r.sample
                    .features
                    .iter()
                    .zip(&coefficients)
                    .map(|(x, b)| x * b)
                    .sum::<f64>()
        })
        .collect();
    // Scale before squaring: tiny but representable residuals must not become zero.
    let rmse = root_mean_square(
        rows.iter()
            .zip(&predictions)
            .map(|(r, y)| r.sample.target - y),
    );
    let target_rms = root_mean_square(rows.iter().map(|r| r.sample.target - mean_y));
    let r_squared = if rows
        .iter()
        .all(|r| r.sample.target == rows[0].sample.target)
    {
        None
    } else {
        Some(1.0 - (rmse / target_rms).powi(2))
    };
    if !coefficients
        .iter()
        .chain(&predictions)
        .chain([&intercept, &rmse, &target_rms])
        .all(|v| v.is_finite())
        || r_squared.is_some_and(|r| !r.is_finite())
    {
        return Err("fit arithmetic overflow; input not consumed".into());
    }
    Ok(json!({
        "kind":"modelCandidate", "approved":false, "assetId":latest.asset_id,
        "candidateId":format!("{}:{}",latest.epoch,latest.sequence),
        "epoch":latest.epoch, "basisModelVersion":latest.model_version,
        "lastSequence":latest.sequence, "featureCount":p, "sampleCount":n,
        "sampleIds":rows.iter().map(|r| &r.sample.sample_id).collect::<Vec<_>>(),
        "firstSampledAt":rows.front().expect("nonempty").sample.sampled_at,
        "lastSampledAt":latest.sampled_at, "fittedAtMs":now,
        "coefficients":coefficients, "intercept":intercept,
        "rmse":rmse, "rSquared":r_squared, "conditionNumber":condition
    }))
}
