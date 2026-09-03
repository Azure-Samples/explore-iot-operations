// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use serde_json::{Map, Value};
use wasm_graph_sdk::macros::map_operator;

/// The map operator is the "main" function for this component.
///
/// Reads the MQTT user properties from the incoming message and embeds them
/// into the JSON payload under the `_user_properties` key, so they survive
/// even if `forward_data` does not propagate `custom_user_data` as outbound
/// MQTT user properties.
///
/// The payload must be a JSON object. User properties with duplicate keys are
/// collected into a JSON array for that key. If there are no user properties,
/// the payload is returned unchanged.
///
/// If the payload already contains a `_user_properties` key:
/// - If it's a JSON object, new properties are merged into it
/// - If it's another type, it's preserved as `_user_properties_original`
#[map_operator]
fn user_props_to_payload(input: DataModel) -> Result<DataModel, Error> {
    let DataModel::Message(mut msg) = input else {
        // WASM graphs in the connectors will always receive a Message input,
        // and must return a Message output.
        unreachable!()
    };

    // Parse the existing payload as a JSON object.
    let mut json: Map<String, Value> =
        serde_json::from_slice(&msg.payload.read()).map_err(to_error)?;

    // Take ownership of the user_properties list. BufferOrString contains WIT
    // resource handles that cannot be cloned, so we must move them out.
    let user_properties = std::mem::take(&mut msg.properties.user_properties);

    if !user_properties.is_empty() {
        // Collect into a JSON object, merging duplicate keys into arrays.
        let mut props: Map<String, Value> = Map::new();
        for (k, v) in user_properties {
            let key = String::from(k);
            let val = Value::String(String::from(v));
            match props.get_mut(&key) {
                Some(Value::Array(arr)) => arr.push(val),
                Some(existing) => {
                    // Promote scalar to array on first duplicate.
                    *existing = Value::Array(vec![existing.clone(), val]);
                }
                None => {
                    props.insert(key, val);
                }
            }
        }

        if let Some(Value::Object(existing_props)) = json.get_mut("_user_properties") {
            // Payload already has a _user_properties object — merge into it.
            let merge_one = |target: &mut Map<String, Value>, key: String, val: Value| {
                match target.get_mut(&key) {
                    Some(Value::Array(arr)) => arr.push(val),
                    Some(existing) => {
                        let prev = existing.clone();
                        *existing = Value::Array(vec![prev, val]);
                    }
                    None => {
                        target.insert(key, val);
                    }
                }
            };
            for (k, v) in props {
                match v {
                    Value::Array(arr) => {
                        for val in arr {
                            merge_one(existing_props, k.clone(), val);
                        }
                    }
                    other => merge_one(existing_props, k, other),
                }
            }
        } else if json.contains_key("_user_properties") {
            // Payload has a _user_properties key that is not an object (e.g. a
            // string or number from the device). Preserve it under a renamed
            // key rather than silently overwriting customer data.
            if let Some(original) = json.remove("_user_properties") {
                json.insert("_user_properties_original".to_owned(), original);
            }
            json.insert("_user_properties".to_owned(), Value::Object(props));
        } else {
            json.insert("_user_properties".to_owned(), Value::Object(props));
        }
    }

    msg.payload = BufferOrBytes::Bytes(serde_json::to_vec(&json).map_err(to_error)?);
    msg.content_type = Some(BufferOrString::String("application/json".to_string()));
    Ok(DataModel::Message(msg))
}

fn to_error(err: impl ToString) -> Error {
    Error {
        message: err.to_string(),
    }
}