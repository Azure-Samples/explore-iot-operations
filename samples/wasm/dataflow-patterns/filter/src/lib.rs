// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#[cfg(any(target_arch = "wasm32", test))]
mod wrapper;

pub fn process_payload(payload: &[u8]) -> Result<bool, String> {
    let output: serde_json::Value =
        serde_json::from_slice(payload).map_err(|error| format!("invalid JSON: {error}"))?;
    let object = output
        .as_object()
        .ok_or_else(|| "payload must be a JSON object".to_owned())?;
    let kind = object
        .get("kind")
        .map(|kind| {
            kind.as_str()
                .ok_or_else(|| "kind must be a string when present".to_owned())
        })
        .transpose()?;
    // SDK filter results are keep predicates, not drop predicates.
    Ok(!matches!(
        kind,
        Some("pending" | "modelApplied" | "diagnostic")
    ))
}
