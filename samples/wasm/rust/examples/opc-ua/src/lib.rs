// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

mod map_opc {
    use serde_json::{json, Map, Value};
    use std::{collections::HashMap, sync::OnceLock};
    use wasm_graph_sdk::macros::map_operator;

    static SCHEMA: OnceLock<String> = OnceLock::new();
    static HEADERS_MAP: OnceLock<HashMap<String, String>> = OnceLock::new();
    static COPY_ALL: OnceLock<bool> = OnceLock::new();

    /// Initializes the module by applying configuration properties.
    ///
    /// The module supports three optional configuration keys:
    ///
    /// **1. `dataschema`**
    /// Incoming OPC UA messages may include a `dataschema` property that describes
    /// the schema of the original payload. Because this module restructures payloads
    /// (flattening OPC UA `DataValue` objects), the original schema may no longer
    /// be valid.
    /// If `dataschema` is provided in the configuration, all incoming messages will
    /// have their schema value overwritten with the new one.
    ///
    /// **2. `headers`**
    /// Incoming messages may contain header properties. Some of these may be meaningful
    /// and should be carried into the flattened payload.
    /// The `headers` configuration is a semicolon-separated list of mappings in the
    /// form:
    ///
    /// ```
    /// "headerName1=columnName1;headerName2=columnName2"
    /// ```
    ///
    /// For each listed header key, its value will be copied into the output payload
    /// under the specified column name.
    ///
    /// **3. `copy_all`**
    /// When set to `true`, any message properties that do **not** match the OPC UA
    /// `DataValue` form (i.e., objects missing `Value` or `SourceTimestamp`) will be
    /// included verbatim in each flattened row.
    /// When `false`, only well-formed `DataValue` entries are included.
    fn opc_init(configuration: ModuleConfiguration) -> bool {
        for (key, value) in configuration.properties {
            match key.as_str() {
                "dataschema" => {
                    _ = SCHEMA.set(value);
                }
                "headers" => {
                    _ = HEADERS_MAP.set(parse_mapping(&value));
                }
                "copy_all" => {
                    if let Ok(v) = value.parse() {
                        _ = COPY_ALL.set(v);
                    }
                }
                _ => {}
            }
        }

        true
    }

    /// Converts an OPC UA-style telemetry map into a database-friendly row array.
    ///
    /// OPC UA telemetry is typically published as a JSON object where each key is a tag
    /// name and each value is an OPC UA `DataValue` object:
    ///
    /// ```json
    /// {
    ///   "Temperature": { "Value": 23.5, "SourceTimestamp": "2024-01-01T00:00:00Z" },
    ///   "Pressure":    { "Value": 101.3, "SourceTimestamp": "2024-01-01T00:00:00Z" }
    /// }
    /// ```
    ///
    /// While this format is useful for telemetry buses, it is not well-suited for
    /// database ingestion, where fixed columns and row-oriented structures work better.
    ///
    /// This function **flattens** the OPC UA tag map by converting each `DataValue` entry
    /// into a standalone row with fixed columns:
    ///
    /// - `tag` — the name of the OPC UA variable (map key)
    /// - `value` — the DataValue’s `Value` field
    /// - `timestamp` — the DataValue’s `SourceTimestamp`
    ///
    /// The output is always a JSON array where **each row corresponds to exactly one tag**.
    ///
    /// Additionally, the function supports two optional enrichment mechanisms:
    ///
    /// ### `copy_all`
    /// Some upstream pipelines enrich messages with additional properties that are *not*
    /// OPC UA `DataValues` (for example: metadata, quality flags, or arbitrary JSON
    /// added by middleware).
    /// When `copy_all = true`, these non-DataValue properties are copied into **every row**.
    ///
    /// ### `headers`
    /// The caller may provide a set of header name/column name pairs that should appear
    /// in the output rows as fixed additional columns.
    /// Each header is injected into every generated row.
    ///
    /// ## Returns
    /// A `Value::Array`, where each element is a flat object containing:
    ///
    /// - OPC UA tag → `tag`
    /// - OPC UA `DataValue` fields → `value`, `timestamp`
    /// - optional enrichment fields (from non-`DataValue` entries)
    /// - optional header fields (from the `headers` map)
    pub fn tag_map_to_array(
        input: &Value,
        copy_all: bool,
        headers: Option<&HashMap<String, String>>,
    ) -> Value {
        let mut rows = Vec::new();
        let mut none_tags = Vec::new();

        // Iterate over all entries in the input object.
        // Split them into:
        //   - valid OPC UA DataValue objects (produce rows)
        //   - "other" properties that may be copied later (none_tags)
        if let Value::Object(map) = input {
            for (tag, v) in map {
                match v {
                    Value::Object(props) => {
                        match (props.get("Value"), props.get("SourceTimestamp")) {
                            // Proper OPC UA DataValue → becomes a row
                            (Some(val), Some(ts)) => {
                                let mut row = Map::new();
                                row.insert("tag".into(), json!(tag));
                                row.insert("value".into(), val.clone());
                                row.insert("timestamp".into(), ts.clone());
                                rows.push(row);
                            }

                            // Object but missing Value or SourceTimestamp → treat as enrichment
                            _ => none_tags.push((tag, v)),
                        }
                    }

                    // Not an object → also enrichment
                    _ => none_tags.push((tag, v)),
                }
            }
        }

        let has_headers = headers.is_some_and(|h| !h.is_empty());
        let has_enrichment = copy_all && !none_tags.is_empty();

        if !has_headers && !has_enrichment {
            return Value::Array(rows.into_iter().map(Value::Object).collect());
        }

        // Enrich each row with extra fields
        for row in &mut rows {
            // Copy non-DataValue fields if configured
            if has_enrichment {
                for &(k, v) in &none_tags {
                    row.insert(k.clone(), v.clone());
                }
            }

            // Inject configured header columns
            if let Some(headers) = headers {
                for (k, v) in headers {
                    row.insert(k.clone(), Value::String(v.clone()));
                }
            }
        }

        Value::Array(rows.into_iter().map(Value::Object).collect())
    }

    /// Extracts selected message properties and maps them into flattened header columns.
    ///
    /// Incoming messages may include custom metadata inside
    /// `message.properties.user_properties`. The module configuration may specify
    /// a `headers` mapping (stored in `HEADERS_MAP`) that defines which of these
    /// properties should appear as additional columns in the final output.
    ///
    /// For each property whose *key* appears in the configured header map,
    /// this function:
    ///   - looks up the corresponding output column name,
    ///   - returns a `HashMap` from `column_name → string_value`.
    ///
    /// If no `headers` mapping was configured, the function returns `None`.
    ///
    /// The resulting header map is later injected into every flattened output row,
    /// ensuring that metadata such as source IDs, type information or pipeline-added
    /// attributes are preserved during the transformation.
    fn create_header_properties(message: &Message) -> Option<HashMap<String, String>> {
        let headers = HEADERS_MAP.get()?;

        Some(
            message
                .properties
                .user_properties
                .iter()
                .filter_map(|(key, value)| {
                    let key = buffer_to_string(key)?;
                    let column = headers.get(&key)?;
                    let value = buffer_to_string(value)?;
                    Some((column.clone(), value))
                })
                .collect(),
        )
    }

    #[map_operator(init = "opc_init")]
    fn opc_flatten(input: DataModel) -> Result<DataModel, Error> {
        let DataModel::Message(mut message) = input else {
            return Err(Error {
                message: "Unexpected input type".into(),
            });
        };

        overwrite_schema(&mut message);
        let headers = create_header_properties(&message);

        let payload_bytes = message.payload.read();
        let payload: Value = serde_json::from_slice(&payload_bytes).map_err(|err| Error {
            message: format!("Failed to deserialize json object. Reason: {err}"),
        })?;

        let copy_all = COPY_ALL.get().copied().unwrap_or(false);
        let flattened = tag_map_to_array(&payload, copy_all, headers.as_ref());

        message.payload = BufferOrBytes::Bytes(
            serde_json::to_vec(&flattened).expect("serialization should never fail for valid JSON"),
        );

        Ok(DataModel::Message(message))
    }

    fn overwrite_schema(message: &mut Message) {
        if let Some(schema) = SCHEMA.get() {
            if let Some((_, value)) = message
                .properties
                .user_properties
                .iter_mut()
                .find(|(key, _)| buffer_to_string(key).as_deref() == Some("dataschema"))
            {
                *value = BufferOrString::String(schema.clone());
            }
        }
    }

    fn parse_mapping(input: &str) -> HashMap<String, String> {
        input
            .split(';')
            .filter_map(|pair| {
                let mut parts = pair.splitn(2, '=');
                match (parts.next(), parts.next()) {
                    (Some(key), Some(value)) if !key.is_empty() && !value.is_empty() => {
                        Some((key.trim().to_string(), value.trim().to_string()))
                    }
                    _ => None,
                }
            })
            .collect()
    }

    fn buffer_to_string(b: &BufferOrString) -> Option<String> {
        match b {
            BufferOrString::String(s) => Some(s.clone()),
            BufferOrString::Buffer(buf) => String::from_utf8(buf.read()).ok(),
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use std::collections::HashMap;

    use crate::map_opc::tag_map_to_array;

    #[test]
    fn basic_extraction() {
        let input = json!({
            "Tag1": {
                "Value": 100,
                "SourceTimestamp": "2026-01-01T00:00:00Z"
            },
            "Tag2": {
                "Value": 200,
                "SourceTimestamp": "2026-01-02T00:00:00Z"
            }
        });

        let result = tag_map_to_array(&input, false, None);

        assert_eq!(
            result,
            json!([
                { "tag": "Tag1", "value": 100, "timestamp": "2026-01-01T00:00:00Z" },
                { "tag": "Tag2", "value": 200, "timestamp": "2026-01-02T00:00:00Z" }
            ])
        );
    }

    #[test]
    fn missing_value_or_ts() {
        let input = json!({
            "Good": {
                "Value": 1,
                "SourceTimestamp": "now"
            },
            "MissingVal": {
                "SourceTimestamp": "now"
            },
            "MissingTs": {
                "Value": 2
            },
            "NotObject": 1234
        });

        let result = tag_map_to_array(&input, false, None);

        assert_eq!(
            result,
            json!([
                { "tag": "Good", "value": 1, "timestamp": "now" }
            ])
        );
    }

    #[test]
    fn copy_all() {
        let input = json!({
            "Tag1": {
                "Value": 100,
                "SourceTimestamp": "2026-01-01T00:00:00Z"
            },
            "Tag2": {
                "Value": 200,
                "SourceTimestamp": "2026-01-02T00:00:00Z"
            },
            "NonTag1": { "Other": 1 },
            "NonTag2": 123
        });

        let result = tag_map_to_array(&input, true, None);

        assert_eq!(
            result,
            json!([
                { "tag": "Tag1", "value": 100, "timestamp": "2026-01-01T00:00:00Z", "NonTag1": { "Other" : 1}, "NonTag2": 123 },
                { "tag": "Tag2", "value": 200, "timestamp": "2026-01-02T00:00:00Z", "NonTag1": { "Other" : 1}, "NonTag2": 123 }
            ])
        );
    }

    #[test]
    fn header_map() {
        let input = json!({
            "A": {
                "Value": "x",
                "SourceTimestamp": "t"
            }
        });

        let headers = map(&[("meta1", "foo"), ("meta2", "bar")]);

        let result = tag_map_to_array(&input, false, Some(&headers));

        assert_eq!(
            result,
            json!([
                {
                    "tag": "A",
                    "value": "x",
                    "timestamp": "t",
                    "meta1": "foo",
                    "meta2": "bar"
                }
            ])
        );
    }

    #[test]
    fn copy_all_and_headers_together() {
        let input = json!({
            "TagX": {
                "Value": "v",
                "SourceTimestamp": "t"
            },
            "None1": { "Unused": true }
        });

        let headers = map(&[("source", "GB"), ("quality", "good")]);

        let result = tag_map_to_array(&input, true, Some(&headers));

        assert_eq!(
            result,
            json!([
                {
                    "tag": "TagX",
                    "value": "v",
                    "timestamp": "t",

                    "None1": { "Unused": true },

                    "source": "GB",
                    "quality": "good"
                }
            ])
        );
    }

    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect()
    }
}
