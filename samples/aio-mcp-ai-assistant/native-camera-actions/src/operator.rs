// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#![allow(clippy::missing_safety_doc)]

use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use wasm_graph_sdk::command_invoker::{self, CommandRequest, FormatIndicator, SerializedPayload};
use wasm_graph_sdk::logger::{self, Level};
use wasm_graph_sdk::macros::map_operator;

use crate::{decode, result, validate, Ledger, Settings};

#[cfg(feature = "get-status")]
const ACTION: &str = "GetStatus";
#[cfg(feature = "continuous-move")]
const ACTION: &str = "ContinuousMove";
#[cfg(feature = "stop")]
const ACTION: &str = "Stop";

static SETTINGS: OnceLock<Settings> = OnceLock::new();
static LEDGER: OnceLock<Mutex<Ledger>> = OnceLock::new();

fn init(configuration: ModuleConfiguration) -> bool {
    let result = Settings::from_properties(&configuration.properties).and_then(|settings| {
        SETTINGS
            .set(settings)
            .map_err(|_| "Module already initialized".into())
    });
    if let Err(error) = result {
        logger::log(Level::Error, "edge-camera-actions", &error);
        return false;
    }
    true
}

fn now() -> Result<f64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs_f64())
        .map_err(|error| format!("Invalid system clock: {error}"))
}

#[map_operator(init = "init")]
fn camera_action(input: DataModel) -> Result<DataModel, Error> {
    let DataModel::Message(mut message) = input else {
        return Err(Error {
            message: "Camera actions require a JSON message".into(),
        });
    };
    let bytes = match &message.payload {
        BufferOrBytes::Buffer(buffer) => buffer.read(),
        BufferOrBytes::Bytes(bytes) => bytes.clone(),
    };
    let request = decode(&bytes).map_err(|message| Error { message })?;
    let settings = SETTINGS.get().ok_or_else(|| Error {
        message: "Module is not initialized".into(),
    })?;
    let response = (|| -> Result<serde_json::Value, String> {
        validate(&request, ACTION, now()?, settings)?;
        if !LEDGER
            .get_or_init(|| Mutex::new(Ledger::default()))
            .lock()
            .map_err(|_| "Request ledger unavailable")?
            .claim(&request.request_id)
        {
            return Err("Duplicate requestId; action was not invoked again".into());
        }
        let response = command_invoker::invoke(&CommandRequest {
            topic: format!(
                "azure-iot-operations/asset-operations/{}/PTZ/{ACTION}",
                settings.asset_name
            ),
            command_name: ACTION.into(),
            payload: SerializedPayload {
                payload: serde_json::to_vec(&request.payload).map_err(|error| error.to_string())?,
                content_type: "application/json".into(),
                format_indicator: FormatIndicator::Utf8EncodedCharacterData,
            },
            custom_user_data: vec![(
                "edge-assistant/requestId".into(),
                request.request_id.clone(),
            )],
            timeout_secs: if ACTION == "Stop" { 8 } else { 2 },
        })
        .map_err(|error| format!("ONVIF managed-action RPC failed: {error:?}"))?;
        serde_json::from_slice(&response.payload.payload)
            .map_err(|error| format!("ONVIF managed-action RPC response is not JSON: {error}"))
    })();
    let output = result(
        &request,
        now().map_err(|message| Error { message })?,
        response,
        settings,
    );
    message.payload = BufferOrBytes::Bytes(serde_json::to_vec(&output).map_err(|error| Error {
        message: error.to_string(),
    })?);
    message.content_type = Some(BufferOrString::String("application/json".into()));
    message.schema = None;
    Ok(DataModel::Message(message))
}
