use std::sync::Mutex;

use chrono::{DateTime, SecondsFormat};
use serde::Serialize;
use wasm_graph_sdk::command_invoker::{self, CommandRequest, FormatIndicator, SerializedPayload};
use wasm_graph_sdk::logger::{self, Level};
use wasm_graph_sdk::macros::map_operator;

#[derive(Clone)]
struct Settings {
    action_topic: String,
    stream_configuration_name: String,
}

static SETTINGS: Mutex<Option<Settings>> = Mutex::new(None);

#[derive(Serialize)]
struct ExtractClipRequest {
    #[serde(rename = "ExtractClip")]
    extract_clip: ExtractClip,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
struct ExtractClip {
    stream_configuration_name: String,
    event_time: String,
    pre_padding_seconds: u32,
    post_padding_seconds: u32,
    target: String,
    mode: String,
}

fn media_capture_init(configuration: ModuleConfiguration) -> bool {
    let setting = |name: &str| {
        configuration
            .properties
            .iter()
            .find_map(|(key, value)| (key == name).then(|| value.clone()))
            .unwrap_or_default()
    };
    let settings = Settings {
        action_topic: setting("action_topic"),
        stream_configuration_name: setting("stream_configuration_name"),
    };
    if settings.action_topic.is_empty()
        || settings.action_topic.contains(['+', '#'])
        || settings.stream_configuration_name.is_empty()
    {
        logger::log(
            Level::Error,
            "media-capture",
            "Set action_topic and stream_configuration_name",
        );
        return false;
    }
    *SETTINGS.lock().unwrap() = Some(settings);
    true
}

#[map_operator(init = "media_capture_init")]
fn media_capture(input: DataModel) -> Result<DataModel, Error> {
    let DataModel::Message(message) = input else {
        return Err(Error {
            message: "Unexpected input type".to_string(),
        });
    };
    let settings = SETTINGS.lock().unwrap().clone().ok_or_else(|| Error {
        message: "The module isn't configured".to_string(),
    })?;

    // The event time is the timestamp of the trigger message, in ISO 8601 UTC.
    let time = &message.timestamp.timestamp;
    let event_time = DateTime::from_timestamp(time.secs as i64, time.nanos)
        .map(|time| time.to_rfc3339_opts(SecondsFormat::Millis, true))
        .ok_or_else(|| Error {
            message: "The message timestamp is out of range".to_string(),
        })?;

    // Copy the snapshots stored in the second before the event to the local shared folder.
    let request = ExtractClipRequest {
        extract_clip: ExtractClip {
            stream_configuration_name: settings.stream_configuration_name,
            event_time,
            pre_padding_seconds: 1,
            post_padding_seconds: 0,
            target: "local-shared".to_string(),
            mode: "CopySource".to_string(),
        },
    };
    let response = command_invoker::invoke(&CommandRequest {
        topic: settings.action_topic,
        command_name: "ExtractClip".to_string(),
        payload: SerializedPayload {
            payload: serde_json::to_vec(&request).map_err(|e| Error {
                message: e.to_string(),
            })?,
            content_type: "application/json".to_string(),
            format_indicator: FormatIndicator::Utf8EncodedCharacterData,
        },
        custom_user_data: Vec::new(),
        timeout_secs: 0,
    })
    .map_err(|e| Error {
        message: format!("ExtractClip command failed: {e:?}"),
    })?;

    // Output the response unchanged, even if it contains an error, such as Busy.
    Ok(DataModel::Message(Message {
        payload: BufferOrBytes::Bytes(response.payload.payload),
        content_type: Some(BufferOrString::String("application/json".to_string())),
        schema: None,
        ..message
    }))
}
