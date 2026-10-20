// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

pub mod align;
pub mod common;
pub mod correlate;
pub mod predictor;
#[cfg(any(target_arch = "wasm32", test))]
mod wrapper;

pub use common::{Config, Result, Role};
use serde_json::Value;

pub struct Engine {
    state: State,
    last_clock: u64,
}

enum State {
    Align(align::Aligner),
    Correlate(correlate::Correlator),
    Predict(predictor::Predictor),
}

impl Engine {
    pub fn new(config: Config) -> Result<Self> {
        // Revalidate programmatically constructed configurations too.
        let config = Config::parse(&serde_json::to_string(&config).map_err(|e| e.to_string())?)?;
        let state = match config.role {
            Role::AlignByTime => State::Align(align::Aligner::new(config)),
            Role::CorrelateById => State::Correlate(correlate::Correlator::new(config)),
            Role::VersionedPredictor => State::Predict(predictor::Predictor::new(config)?),
        };
        Ok(Self {
            state,
            last_clock: 0,
        })
    }

    pub fn process(&mut self, input: &[u8], now_ms: u64) -> Result<Value> {
        if input.len() > 65_536 {
            return Err("payload exceeds 65536 bytes".into());
        }
        if now_ms < self.last_clock {
            return Err("processing clock moved backwards".into());
        }
        self.last_clock = now_ms;
        let v: Value = serde_json::from_slice(input).map_err(|e| format!("invalid JSON: {e}"))?;
        if !v.is_object() {
            return Err("payload must be a JSON object".into());
        }
        match &mut self.state {
            State::Align(s) => s.process(v, now_ms),
            State::Correlate(s) => s.process(v, now_ms),
            State::Predict(s) => s.process(v, now_ms),
        }
    }
}
