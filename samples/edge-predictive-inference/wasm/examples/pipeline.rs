// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use edge_predictive_inference::{finish_frame, prepare_frame, FrameContext, Settings};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

fn now_ms() -> Result<u64, Box<dyn std::error::Error>> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)?
        .as_millis()
        .try_into()?)
}

fn create(path: &Path, bytes: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?
        .write_all(bytes)?;
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [command, jpeg, output] if command == "prepare" => {
            let (context, tensor) =
                prepare_frame(&fs::read(jpeg)?, Settings::default(), now_ms()?, Uuid::new_v4())?;
            let directory = Path::new(output);
            fs::create_dir_all(directory)?;
            let request = directory.join(&context.input_reference);
            let metadata = directory.join(format!("{}.context.json", context.frame_id));
            create(&request, &tensor)?;
            create(&metadata, &serde_json::to_vec_pretty(&context)?)?;
            println!("{}", serde_json::json!({"request": request, "context": metadata}));
        }
        [command, context, response] if command == "finish" => {
            let context = FrameContext::parse(&fs::read(context)?)?;
            let response = Path::new(response);
            let reference = response.file_name().and_then(|v| v.to_str()).ok_or("Invalid response name")?;
            let result = finish_frame(&context, reference, &fs::read(response)?, now_ms()?)?;
            println!("{}", serde_json::to_string_pretty(&result)?);
        }
        _ => return Err("Usage: pipeline prepare IMAGE.jpg OUTPUT_DIR | pipeline finish CONTEXT.json RESPONSE_FILE".into()),
    }
    Ok(())
}
