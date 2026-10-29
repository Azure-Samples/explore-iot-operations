// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// The SDK generates unsafe ABI traits without Safety documentation.
#![allow(clippy::missing_safety_doc)]

#[wasm_graph_sdk::macros::filter_operator]
fn filter(input: DataModel) -> Result<bool, Error> {
    let DataModel::Message(message) = input else {
        return Err(Error {
            message: "expected Message input".into(),
        });
    };
    crate::process_payload(&message.payload.read()).map_err(|message| Error { message })
}

#[cfg(test)]
fn process_payload(payload: &[u8]) -> Result<bool, Error> {
    use exports::wasm_graph::processor::filter::Guest;
    <Module as Guest>::process(DataModel::Message(Message {
        timestamp: Timestamp {
            timestamp: wasm_graph::processor::hybrid_logical_clock::Timespec { secs: 0, nanos: 0 },
            counter: 0,
            node_id: BufferOrString::String("test".into()),
        },
        topic: BufferOrBytes::Bytes(b"factory/output".to_vec()),
        content_type: Some(BufferOrString::String("application/json".into())),
        payload: BufferOrBytes::Bytes(payload.to_vec()),
        properties: MessageProperties {
            user_properties: vec![],
        },
        schema: None,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use exports::wasm_graph::processor::filter::Guest;
    use serde_json::json;

    #[test]
    fn generated_guest_initializes_without_rules_and_drops_only_internal_records() {
        assert!(<Module as Guest>::init(ModuleConfiguration {
            properties: vec![],
            module_schemas: vec![],
        }));
        for kind in ["pending", "modelApplied", "diagnostic"] {
            assert!(!process_payload(json!({"kind": kind}).to_string().as_bytes()).unwrap());
        }
        for output in [
            json!({"assetId":"a","speed":12,"temperature":20}),
            json!({"kind":"correlated","residual":-3}),
            json!({"kind":"prediction","predictedWeight":203}),
            json!({"kind":"batch","records":[{"speed":12},{"speed":13}]}),
        ] {
            assert!(process_payload(output.to_string().as_bytes()).unwrap());
        }
    }

    #[test]
    fn generated_guest_rejects_invalid_datamodel_json_and_payload_types() {
        assert!(
            <Module as Guest>::process(DataModel::BufferOrBytes(BufferOrBytes::Bytes(vec![])))
                .is_err()
        );
        for payload in [
            "{",
            "null",
            "[]",
            "42",
            "\"pending\"",
            r#"{"kind":null}"#,
            r#"{"kind":false}"#,
            r#"{"kind":1}"#,
            r#"{"kind":[]}"#,
            r#"{"kind":{}}"#,
        ] {
            assert!(process_payload(payload.as_bytes()).is_err(), "{payload}");
        }
    }
}
