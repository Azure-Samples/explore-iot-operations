use serde::Deserialize;
use wasm_graph_sdk::macros::map_operator;

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ExtractClipResponse {
    result: Option<ExtractClipResult>,
    error: Option<serde_json::Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ExtractClipResult {
    #[serde(default)]
    source_files: Vec<SourceFile>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct SourceFile {
    target_path: Option<String>,
    copy_status: Option<String>,
    offset_from_event_time_milliseconds: Option<f64>,
}

/// Returns the path of the copied snapshot that's nearest to the event time.
fn nearest_snapshot(payload: &[u8]) -> Result<String, String> {
    let response: ExtractClipResponse = serde_json::from_slice(payload)
        .map_err(|e| format!("The payload isn't an ExtractClip response: {e}"))?;
    let Some(result) = response.result else {
        return Err(format!(
            "ExtractClip failed: {}",
            response.error.unwrap_or_default()
        ));
    };
    result
        .source_files
        .into_iter()
        .filter(|file| matches!(file.copy_status.as_deref(), Some("Copied" | "Skipped")))
        .filter_map(|file| {
            Some((
                file.offset_from_event_time_milliseconds?.abs(),
                file.target_path?,
            ))
        })
        .min_by(|a, b| a.0.total_cmp(&b.0))
        .map(|(_, path)| path)
        .ok_or_else(|| "The response doesn't contain a copied snapshot".to_string())
}

#[map_operator]
fn select_snapshot(input: DataModel) -> Result<DataModel, Error> {
    let DataModel::Message(message) = input else {
        return Err(Error {
            message: "Unexpected input type".to_string(),
        });
    };
    let path = nearest_snapshot(&message.payload.read()).map_err(|message| Error { message })?;

    // The path is relative to the media connector's localSharedPath folder.
    Ok(DataModel::Message(Message {
        payload: BufferOrBytes::Bytes(path.into_bytes()),
        content_type: Some(BufferOrString::String("text/plain".to_string())),
        schema: None,
        ..message
    }))
}

#[cfg(test)]
mod tests {
    use super::nearest_snapshot;

    #[test]
    fn picks_nearest_copied_snapshot() {
        let payload = br#"{"Result":{"SourceTier":"local-storage","SourceFiles":[
            {"Path":"/tmp/a.jpg","Timestamp":"t","OffsetFromEventTimeMilliseconds":-1200.0,"CopyStatus":"Copied","TargetPath":"recordings/d/rtsp/a/snapshots/a.jpg"},
            {"Path":"/tmp/b.jpg","Timestamp":"t","OffsetFromEventTimeMilliseconds":-200.5,"CopyStatus":"Copied","TargetPath":"recordings/d/rtsp/a/snapshots/b.jpg"},
            {"Path":"/tmp/c.jpg","Timestamp":"t","OffsetFromEventTimeMilliseconds":-10.0,"CopyStatus":"Failed","TargetPath":"recordings/d/rtsp/a/snapshots/c.jpg"}],"Failures":[]}}"#;
        assert_eq!(
            nearest_snapshot(payload).unwrap(),
            "recordings/d/rtsp/a/snapshots/b.jpg"
        );
    }

    #[test]
    fn reports_errors() {
        let busy =
            br#"{"Error":{"Message":"Busy: source stream already has an active file operation"}}"#;
        assert!(nearest_snapshot(busy).unwrap_err().contains("Busy"));
        let none = br#"{"Result":{"SourceFiles":[]}}"#;
        assert!(nearest_snapshot(none).is_err());
    }
}
