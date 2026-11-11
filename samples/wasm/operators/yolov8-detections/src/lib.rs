use std::collections::HashMap;
use std::sync::Mutex;

use serde::Serialize;
use wasm_graph_sdk::command_invoker::{self, CommandRequest, FormatIndicator, SerializedPayload};
use wasm_graph_sdk::file_store;
use wasm_graph_sdk::logger::{self, Level};
use wasm_graph_sdk::macros::map_operator;

// The id of the data flow's file store for the inference connector's write folder.
const RESPONSES_STORE: &str = "responses";

#[derive(Clone)]
struct Settings {
    model_name: String,
    output_name: String,
    confidence_threshold: f64,
}

static SETTINGS: Mutex<Option<Settings>> = Mutex::new(None);
static LABELS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

#[derive(Serialize)]
struct Detection {
    label: String,
    confidence: f64,
    #[serde(rename = "box")]
    bounding_box: [f64; 4],
}

fn detections_init(configuration: ModuleConfiguration) -> bool {
    let setting = |name: &str| {
        configuration
            .properties
            .iter()
            .find_map(|(key, value)| (key == name).then(|| value.clone()))
    };
    let model_name = setting("model_name").unwrap_or_default();
    let output_name = setting("output_name").unwrap_or_default();
    let confidence_threshold = setting("confidence_threshold")
        .unwrap_or_else(|| "0.55".to_string())
        .parse::<f64>();
    // The model name is a level of the command topic.
    let valid_model_name = !model_name.is_empty() && !model_name.contains(['/', '+', '#']);
    match confidence_threshold {
        Ok(confidence_threshold) if valid_model_name && !output_name.is_empty() => {
            *SETTINGS.lock().unwrap() = Some(Settings {
                model_name,
                output_name,
                confidence_threshold,
            });
            true
        }
        _ => {
            logger::log(
                Level::Error,
                "yolov8-detections",
                "Set model_name, output_name, and a numeric confidence_threshold",
            );
            false
        }
    }
}

/// Gets the class labels of the model from the inference connector, once.
fn labels(model_name: &str) -> Result<HashMap<String, String>, String> {
    if let Some(labels) = LABELS.lock().unwrap().as_ref() {
        return Ok(labels.clone());
    }
    let response = command_invoker::invoke(&CommandRequest {
        topic: format!("aio/inference/command/getModelInfo/model_name/{model_name}"),
        command_name: "getModelInfo".to_string(),
        payload: SerializedPayload {
            payload: b"{}".to_vec(),
            content_type: "application/json".to_string(),
            format_indicator: FormatIndicator::Utf8EncodedCharacterData,
        },
        custom_user_data: Vec::new(),
        timeout_secs: 0,
    })
    .map_err(|e| format!("getModelInfo command failed: {e:?}"))?;
    let info: serde_json::Value =
        serde_json::from_slice(&response.payload.payload).map_err(|e| e.to_string())?;
    if let Some(error) = info.get("getModelInfoError") {
        return Err(format!("getModelInfo failed: {error}"));
    }
    let labels: HashMap<String, String> = info["id2label"]
        .as_object()
        .map(|map| {
            map.iter()
                .filter_map(|(id, label)| Some((id.clone(), label.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default();
    *LABELS.lock().unwrap() = Some(labels.clone());
    Ok(labels)
}

/// Converts the output of a YOLOv8 model with non-maximum suppression, which
/// contains one row of [x1, y1, x2, y2, confidence, class id] values for each
/// detection, into labeled detections.
fn to_detections(
    output: &[u8],
    settings: &Settings,
    labels: &HashMap<String, String>,
) -> Result<Vec<Detection>, String> {
    let output: serde_json::Value =
        serde_json::from_slice(output).map_err(|e| format!("The model output isn't JSON: {e}"))?;
    let rows = output[settings.output_name.as_str()][0]
        .as_array()
        .ok_or_else(|| format!("The model output has no '{}' rows", settings.output_name))?;
    let mut detections = Vec::new();
    for row in rows {
        let values: Vec<f64> = row
            .as_array()
            .map(|row| row.iter().filter_map(serde_json::Value::as_f64).collect())
            .unwrap_or_default();
        let [x1, y1, x2, y2, confidence, class_id] = values[..] else {
            return Err("Each row of the model output must contain six numbers".to_string());
        };
        if confidence < settings.confidence_threshold {
            continue;
        }
        let class_id = (class_id as u64).to_string();
        detections.push(Detection {
            label: labels.get(&class_id).cloned().unwrap_or(class_id),
            confidence: (confidence * 100.0).round() / 100.0,
            bounding_box: [x1.round(), y1.round(), x2.round(), y2.round()],
        });
    }
    Ok(detections)
}

#[map_operator(init = "detections_init")]
fn detections(input: DataModel) -> Result<DataModel, Error> {
    let DataModel::Message(message) = input else {
        return Err(Error {
            message: "Unexpected input type".to_string(),
        });
    };
    let settings = SETTINGS.lock().unwrap().clone().ok_or_else(|| Error {
        message: "The module isn't configured".to_string(),
    })?;

    // The payload is the name of the file that contains the model output.
    let file_name = String::from_utf8(message.payload.read()).map_err(|e| Error {
        message: format!("The payload isn't a file name: {e}"),
    })?;
    let output = file_store::get(RESPONSES_STORE, file_name.trim()).map_err(|e| Error {
        message: format!("Can't read the model output '{file_name}': {e:?}"),
    })?;

    let labels = labels(&settings.model_name).map_err(|message| Error { message })?;
    let detections =
        to_detections(&output, &settings, &labels).map_err(|message| Error { message })?;

    Ok(DataModel::Message(Message {
        payload: BufferOrBytes::Bytes(serde_json::to_vec(&detections).map_err(|e| Error {
            message: e.to_string(),
        })?),
        content_type: Some(BufferOrString::String("application/json".to_string())),
        schema: None,
        ..message
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_yolo_rows() {
        let settings = Settings {
            model_name: "m".into(),
            output_name: "output0_0".into(),
            confidence_threshold: 0.55,
        };
        let labels = HashMap::from([("15".to_string(), "cat".to_string())]);
        let output = br#"{"output0_0": [[[5.17, 0.93, 558.45, 638.12, 0.7804, 15.0], [0.0, 0.0, 0.0, 0.0, 0.0, 0.0], [1, 2, 3, 4, 0.9, 3]]]}"#;
        let json =
            serde_json::to_string(&to_detections(output, &settings, &labels).unwrap()).unwrap();
        assert_eq!(
            json,
            r#"[{"label":"cat","confidence":0.78,"box":[5.0,1.0,558.0,638.0]},{"label":"3","confidence":0.9,"box":[1.0,2.0,3.0,4.0]}]"#
        );
    }
}
