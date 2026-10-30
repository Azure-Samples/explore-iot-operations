// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;
use uuid::Uuid;

pub mod yolox;

#[cfg(all(feature = "preprocess", feature = "postprocess"))]
compile_error!("Build preprocess and postprocess separately");

#[cfg(all(
    target_arch = "wasm32",
    not(any(feature = "preprocess", feature = "postprocess"))
))]
compile_error!("Select the preprocess or postprocess feature for a WASM build");

#[cfg(target_arch = "wasm32")]
mod operator;

pub const INPUT_STORE: &str = "person-inputs";
pub const OUTPUT_STORE: &str = "person-responses";
pub const CONTEXT_KEY: &str = "edge-predictive-inference/context";
pub const MAX_RESPONSE_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    pub camera_id: String,
    pub model_name: String,
    pub score_threshold: f32,
    pub nms_threshold: f32,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            camera_id: "edge-person-camera".into(),
            model_name: "edge-person-yolox".into(),
            score_threshold: 0.30,
            nms_threshold: 0.45,
        }
    }
}

impl Settings {
    pub fn validate(&self) -> Result<(), String> {
        for value in [&self.camera_id, &self.model_name] {
            if value.is_empty()
                || value.len() > 63
                || !value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
            {
                return Err(
                    "Camera and model identifiers must be 1-63 safe ASCII characters".into(),
                );
            }
        }
        if !(0.0..=1.0).contains(&self.score_threshold)
            || self.score_threshold == 0.0
            || !(0.0..=1.0).contains(&self.nms_threshold)
        {
            return Err("Score must be in (0,1] and NMS threshold in [0,1]".into());
        }
        Ok(())
    }

    pub fn from_properties(properties: &[(String, String)]) -> Result<Self, String> {
        let mut settings = Self::default();
        let mut seen = HashSet::new();
        for (key, value) in properties {
            if !seen.insert(key.as_str()) {
                return Err(format!("Duplicate module setting: {key}"));
            }
            match key.as_str() {
                "camera_id" => settings.camera_id = value.clone(),
                "model_name" => settings.model_name = value.clone(),
                "score_threshold" => {
                    settings.score_threshold = value.parse().map_err(|e| format!("Score: {e}"))?;
                }
                "nms_threshold" => {
                    settings.nms_threshold = value.parse().map_err(|e| format!("NMS: {e}"))?;
                }
                _ => return Err(format!("Unknown module setting: {key}")),
            }
        }
        if !seen.contains("camera_id") || !seen.contains("model_name") {
            return Err("camera_id and model_name are required".into());
        }
        settings.validate()?;
        Ok(settings)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FrameContext {
    pub version: u8,
    pub frame_id: Uuid,
    pub started_at_unix_ms: u64,
    pub settings: Settings,
    pub image: yolox::Geometry,
    pub input_reference: String,
}

impl FrameContext {
    pub fn validate(&self) -> Result<(), String> {
        if self.version != 1
            || self.frame_id.is_nil()
            || self.input_reference != format!("{}.json", self.frame_id)
        {
            return Err("Invalid frame context version, ID, or input reference".into());
        }
        self.settings.validate()?;
        self.image.validate()
    }

    pub fn parse(raw: &[u8]) -> Result<Self, String> {
        if raw.len() > 4096 {
            return Err("Frame context exceeds 4 KiB".into());
        }
        let context: Self =
            serde_json::from_slice(raw).map_err(|e| format!("Invalid frame context: {e}"))?;
        context.validate()?;
        Ok(context)
    }
}

pub fn prepare_frame(
    jpeg: &[u8],
    settings: Settings,
    started_at_unix_ms: u64,
    frame_id: Uuid,
) -> Result<(FrameContext, Vec<u8>), String> {
    settings.validate()?;
    let prepared = yolox::prepare(jpeg)?;
    let context = FrameContext {
        version: 1,
        frame_id,
        started_at_unix_ms,
        settings,
        image: prepared.geometry,
        input_reference: format!("{frame_id}.json"),
    };
    context.validate()?;
    let channels: Vec<Vec<&[f32]>> = prepared
        .values
        .chunks(yolox::SIZE * yolox::SIZE)
        .map(|channel| channel.chunks(yolox::SIZE).collect())
        .collect();
    let tensor = serde_json::to_vec(&[channels]).map_err(|e| format!("Encoding tensor: {e}"))?;
    Ok((context, tensor))
}

pub fn validate_reference(reference: &str) -> Result<(), String> {
    if reference.is_empty()
        || reference.len() > 128
        || reference == "."
        || reference == ".."
        || !reference
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    {
        return Err("Expected a single, relative file name in the configured store".into());
    }
    Ok(())
}

fn observation(context: &FrameContext, now_ms: u64) -> Result<Value, String> {
    context.validate()?;
    let elapsed = now_ms
        .checked_sub(context.started_at_unix_ms)
        .ok_or("System clock moved backwards during inference")?;
    Ok(json!({
        "schemaVersion": 1,
        "frameId": context.frame_id,
        "cameraId": context.settings.camera_id,
        "modelName": context.settings.model_name,
        "inferenceHost": "foundry-local",
        "processingStartedAtUnixMs": context.started_at_unix_ms,
        "processedAtUnixMs": now_ms,
        "processingMilliseconds": elapsed,
        "image": context.image,
        "files": {"request": context.input_reference},
    }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TensorResponse {
    output_0: Vec<Vec<Vec<f32>>>,
}

fn json_value(value: &impl Serialize) -> Result<Value, String> {
    // Serialize FP32 values before using Value, which otherwise widens them to FP64.
    let bytes = serde_json::to_vec(value).map_err(|e| format!("Encoding observation: {e}"))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("Encoding observation: {e}"))
}

pub fn finish_frame(
    context: &FrameContext,
    output_reference: &str,
    raw: &[u8],
    now_ms: u64,
) -> Result<Value, String> {
    validate_reference(output_reference)?;
    if raw.len() > MAX_RESPONSE_BYTES {
        return Err("Model response exceeds 32 MiB".into());
    }
    let mut response: TensorResponse =
        serde_json::from_slice(raw).map_err(|e| format!("Invalid model JSON: {e}"))?;
    if response.output_0.len() != 1 {
        return Err("Expected one [1,3549,85] output_0 tensor".into());
    }
    let rows = response.output_0.remove(0);
    let detections = yolox::decode(&rows, &context.image, &context.settings)?;
    let mut result = observation(context, now_ms)?;
    result["status"] = "ok".into();
    result["personCount"] = detections.len().into();
    result["detectionLimitReached"] = (detections.len() == yolox::MAX_DETECTIONS).into();
    result["detections"] = json_value(&detections)?;
    result["scoreThreshold"] = json_value(&context.settings.score_threshold)?;
    result["nmsThreshold"] = json_value(&context.settings.nms_threshold)?;
    result["files"]["response"] = output_reference.into();
    Ok(result)
}

pub fn failed_frame(
    context: &FrameContext,
    output_reference: Option<&str>,
    message: &str,
    now_ms: u64,
) -> Result<Value, String> {
    if message.is_empty() {
        return Err("An inference failure must include a reason".into());
    }
    let mut result = observation(context, now_ms)?;
    result["status"] = "error".into();
    result["error"] = json!({"stage": "postprocess", "message": message});
    if let Some(reference) = output_reference {
        validate_reference(reference)?;
        result["files"]["response"] = reference.into();
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> FrameContext {
        let id = Uuid::from_u128(123);
        FrameContext {
            version: 1,
            frame_id: id,
            started_at_unix_ms: 1000,
            settings: Settings::default(),
            image: yolox::Geometry {
                width: 832,
                height: 416,
            },
            input_reference: format!("{id}.json"),
        }
    }

    #[test]
    fn preserves_frame_and_file_identity_for_empty_and_failed_predictions() {
        let raw = serde_json::to_vec(&json!({"output_0": [vec![vec![0.0; 85]; 3549]]})).unwrap();
        let result = finish_frame(&context(), "response-123", &raw, 1250).unwrap();
        assert_eq!(result["status"], "ok");
        assert_eq!(result["personCount"], 0);
        assert_eq!(result["files"]["request"], context().input_reference);
        assert_eq!(result["files"]["response"], "response-123");
        assert_eq!(result["processingMilliseconds"], 250);
        let failure =
            failed_frame(&context(), Some("response-123"), "Missing output", 1250).unwrap();
        assert_eq!(failure["status"], "error");
        assert_eq!(failure["frameId"], result["frameId"]);
        assert!(failure.get("personCount").is_none());
        assert!(failure.get("detections").is_none());
    }

    #[test]
    fn rejects_bad_contracts_instead_of_reporting_zero_people() {
        for raw in [
            br#"{}"#.as_slice(),
            br#"{"output_0":[]}"#,
            br#"{"output_0":[[[0]]] }"#,
            br#"{"output_0":[[[1e999]]] }"#,
            br#"{"output_0":[],"other":[]}"#,
        ] {
            assert!(finish_frame(&context(), "output", raw, 1250).is_err());
        }
        assert!(failed_frame(&context(), None, "failure", 999).is_err());
        for path in ["", ".", "..", "../file", "/file", "a/b", r"a\b", "file\n"] {
            assert!(validate_reference(path).is_err(), "{path:?}");
        }
        let mut changed = context();
        changed.input_reference = "unrelated.json".into();
        assert!(FrameContext::parse(&serde_json::to_vec(&changed).unwrap()).is_err());
        changed = context();
        changed.image.width = 0;
        assert!(changed.validate().is_err());
    }

    #[test]
    fn validates_settings_and_rejects_duplicate_or_unknown_configuration() {
        let properties = vec![
            ("camera_id".into(), "camera-1".into()),
            ("model_name".into(), "yolox".into()),
            ("score_threshold".into(), "0.7".into()),
        ];
        assert_eq!(
            Settings::from_properties(&properties)
                .unwrap()
                .score_threshold,
            0.7
        );
        for extra in [
            ("camera_id".into(), "camera-2".into()),
            ("unknown".into(), "value".into()),
            ("nms_threshold".into(), "NaN".into()),
        ] {
            let mut invalid = properties.clone();
            invalid.push(extra);
            assert!(Settings::from_properties(&invalid).is_err());
        }
        assert!(Settings::from_properties(&[]).is_err());
    }

    #[test]
    fn emits_batched_unnormalized_bgr_json_and_a_matching_context() {
        let image = image::RgbImage::from_pixel(4, 2, image::Rgb([10, 20, 30]));
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 100)
            .encode_image(&image)
            .unwrap();
        let (context, raw) =
            prepare_frame(&jpeg, Settings::default(), 1000, Uuid::from_u128(123)).unwrap();
        let tensor: Vec<Vec<Vec<Vec<f32>>>> = serde_json::from_slice(&raw).unwrap();
        assert_eq!(
            (tensor.len(), tensor[0].len(), tensor[0][0].len()),
            (1, 3, 416)
        );
        assert_eq!(tensor[0][0][0].len(), 416);
        assert!((tensor[0][0][0][0] - 30.0).abs() < 3.0);
        assert!((tensor[0][2][0][0] - 10.0).abs() < 3.0);
        assert_eq!(tensor[0][0][300][0], 114.0);
        assert_eq!((context.image.width, context.image.height), (4, 2));
        assert!(FrameContext::parse(&serde_json::to_vec(&context).unwrap()).is_ok());
        assert!(prepare_frame(b"invalid", Settings::default(), 1000, Uuid::new_v4()).is_err());
    }
}
