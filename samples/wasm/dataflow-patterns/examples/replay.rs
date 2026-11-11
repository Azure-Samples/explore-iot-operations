// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//! cargo run --locked --example replay -- fixtures/align-by-time.json
//! Each fixture gives exact MQTT topics, input payloads, and expected graph
//! payloads (null means no delivery). nowMs is a deterministic test clock.
//! This driver runs the same core, not the AIO runtime or its built-in filter.
use module_dataflow_patterns::{Config, Engine};
use serde_json::Value;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args()
        .nth(1)
        .ok_or("usage: replay FIXTURE.json")?;
    let fixture: Value = serde_json::from_slice(&std::fs::read(path)?)?;
    let mut engine = Engine::new(Config::parse(&fixture["configuration"].to_string())?)?;
    for step in fixture["steps"]
        .as_array()
        .ok_or("steps must be an array")?
    {
        let output = engine.process(
            step["input"].to_string().as_bytes(),
            step["nowMs"]
                .as_u64()
                .ok_or("nowMs must be an unsigned integer")?,
        )?;
        println!("{output}");
    }
    Ok(())
}
