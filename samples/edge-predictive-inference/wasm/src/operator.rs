// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#![allow(clippy::missing_safety_doc)]

#[cfg(feature = "postprocess")]
use crate::FrameContext;
use crate::{Settings, CONTEXT_KEY};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};
use wasm_graph_sdk::file_store;
use wasm_graph_sdk::logger::{self, Level};
use wasm_graph_sdk::macros::map_operator;

static SETTINGS: OnceLock<Settings> = OnceLock::new();

fn log_error(message: &str) {
    logger::log(Level::Error, "edge-predictive-inference", message);
}

fn init(configuration: ModuleConfiguration) -> bool {
    match Settings::from_properties(&configuration.properties) {
        Ok(settings) => match SETTINGS.set(settings) {
            Ok(()) => true,
            Err(_) => {
                log_error("Module initialized more than once");
                false
            }
        },
        Err(error) => {
            log_error(&error);
            false
        }
    }
}

fn now_ms() -> Result<u64, String> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("Invalid system clock: {e}"))?;
    u64::try_from(elapsed.as_millis()).map_err(|e| format!("Invalid timestamp: {e}"))
}

fn text(value: &BufferOrString) -> Result<String, String> {
    match value {
        BufferOrString::String(value) => Ok(value.clone()),
        BufferOrString::Buffer(value) => {
            String::from_utf8(value.read()).map_err(|e| format!("Invalid UTF-8 property: {e}"))
        }
    }
}

#[cfg(feature = "preprocess")]
fn transform(
    message: &mut Message,
    payload: &[u8],
    context: Option<(usize, String)>,
) -> Result<(), String> {
    if context.is_some() {
        return Err("Source message contains the reserved frame context property".into());
    }
    let id = uuid::Uuid::new_v4();
    let settings = SETTINGS.get().ok_or("Module is not initialized")?.clone();
    let (context, tensor) = crate::prepare_frame(payload, settings, now_ms()?, id)
        .map_err(|e| format!("Frame {id}: {e}"))?;
    file_store::set(crate::INPUT_STORE, &context.input_reference, &tensor)
        .map_err(|e| format!("Frame {id}: writing input tensor failed: {e:?}"))?;
    let property = serde_json::to_string(&context).map_err(|e| format!("Frame {id}: {e}"))?;
    message.properties.user_properties.push((
        BufferOrString::String(CONTEXT_KEY.into()),
        BufferOrString::String(property),
    ));
    message.payload = BufferOrBytes::Bytes(context.input_reference.into_bytes());
    logger::log(
        Level::Info,
        "edge-predictive-inference",
        &format!("Prepared frame {id} for native inference"),
    );
    Ok(())
}

#[cfg(feature = "postprocess")]
fn transform(
    message: &mut Message,
    payload: &[u8],
    context: Option<(usize, String)>,
) -> Result<(), String> {
    let (index, raw_context) = context.ok_or("Inference response has no frame context")?;
    let context = FrameContext::parse(raw_context.as_bytes())?;
    if &context.settings != SETTINGS.get().ok_or("Module is not initialized")? {
        return Err("Preprocessing and postprocessing configuration do not match".into());
    }
    let mut output_reference = None;
    let result: Result<serde_json::Value, String> = (|| {
        if message
            .content_type
            .as_ref()
            .map(text)
            .transpose()?
            .as_deref()
            != Some("text/plain")
        {
            return Err("Expected the inference 0.2 plain-file-reference contract".into());
        }
        let reference =
            std::str::from_utf8(payload).map_err(|e| format!("Invalid output reference: {e}"))?;
        crate::validate_reference(reference)?;
        output_reference = Some(reference);
        let raw = file_store::get(crate::OUTPUT_STORE, reference)
            .map_err(|e| format!("Reading response failed: {e:?}"))?;
        crate::finish_frame(&context, reference, &raw, now_ms()?)
    })();
    let (topic, result) = match result {
        Ok(result) => ("results", result),
        Err(error) => {
            log_error(&format!("Frame {}: {error}", context.frame_id));
            (
                "errors",
                crate::failed_frame(&context, output_reference, &error, now_ms()?)?,
            )
        }
    };
    message.properties.user_properties.remove(index);
    message.topic = BufferOrBytes::Bytes(topic.as_bytes().to_vec());
    message.payload = BufferOrBytes::Bytes(
        serde_json::to_vec(&result).map_err(|e| format!("Encoding observation: {e}"))?,
    );
    Ok(())
}

#[map_operator(init = "init")]
fn process(input: DataModel) -> Result<DataModel, Error> {
    let result: Result<DataModel, String> = (|| {
        let DataModel::Message(mut message) = input else {
            return Err("Expected a JPEG MQTT Message".into());
        };
        let payload = match &message.payload {
            BufferOrBytes::Buffer(buffer) => buffer.read(),
            BufferOrBytes::Bytes(bytes) => bytes.clone(),
        };
        let mut context = None;
        for (index, (key, value)) in message.properties.user_properties.iter().enumerate() {
            if text(key)? == CONTEXT_KEY {
                if context.is_some() {
                    return Err("Duplicate frame context properties".into());
                }
                context = Some((index, text(value)?));
            }
        }
        transform(&mut message, &payload, context)?;
        message.content_type = Some(BufferOrString::String("application/json".into()));
        message.schema = None;
        Ok(DataModel::Message(message))
    })();
    result.map_err(|message| {
        log_error(&message);
        Error { message }
    })
}
