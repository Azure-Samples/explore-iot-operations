// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#![allow(clippy::missing_safety_doc)]
mod otel_enrich {

    use std::sync::OnceLock;
    use std::vec;

    use wasm_graph_sdk::logger::{self, Level};
    use wasm_graph_sdk::macros::map_operator;
    use wasm_graph_sdk::metrics::{self, CounterValue, Label};
    use wasm_graph_sdk::state_store::{self};

    static ATTR_KEYS: OnceLock<String> = OnceLock::new();

    fn enrich_init(configuration: ModuleConfiguration) -> bool {
        logger::log(
            Level::Info,
            "module-otel-enrich/map",
            "Initialization function invoked",
        );

        for (key, value) in configuration.properties {
            logger::log(
                Level::Info,
                "module-otel-enrich/map",
                &format!("Initialization received the property (key='{key}', value='{value}')."),
            );

            match key.as_str() {
                "enrichKeys" => {
                    ATTR_KEYS.set(value.clone()).unwrap_or_else(|_| {
                        logger::log(
                            Level::Error,
                            "module-otel-enrich/map",
                            "Failed to set enrichKeys in ATTR_KEYS",
                        );
                    });
                }
                _ => {
                    logger::log(
                        Level::Warn,
                        "module-otel-enrich/map",
                        &format!("Unknown property key '{key}'"),
                    );
                }
            }
        }

        true
    }

    #[map_operator(init = "enrich_init")]
    fn factory_id_enrich(input: DataModel) -> Result<DataModel, Error> {
        let labels = vec![Label {
            key: "module".to_owned(),
            value: "module-otel-enrich/map".to_owned(),
        }];
        let _ = metrics::add_to_counter("requests", CounterValue::U64(1), Some(&labels));

        // Extract message from input
        let DataModel::Message(mut result) = input else {
            return Err(Error { message: "Unexpected input type".to_string() });
        };

        // Get list of keys to enrich from ATTR_KEYS
        let Some(attr_keys) = ATTR_KEYS.get() else {
            logger::log(
                Level::Error,
                "module-otel-enrich/map",
                "ATTR_KEYS is not initialized, cannot enrich message",
            );
            return Ok(DataModel::Message(result));
        };
        let keys: Vec<&str> = attr_keys.split(',').collect();

        let mut user_properties_vec = result.properties.user_properties;

        for key in keys {
            let key = key.trim();
            if key.is_empty() {
                continue; // Skip empty keys
            }

            // Get value from DSS
            let state_store_get = state_store::get(key.as_bytes(), None);
            match state_store_get
                .as_ref()
                .map(|value| value.response.as_deref())
            {
                Ok(Some(value)) => {
                    logger::log(
                        Level::Debug,
                        "module-otel-enrich/map",
                        &format!("Retrieved from state store: key='{key}', value='{value:?}'"),
                    );
                    let stringify = String::from_utf8_lossy(value).to_string();
                    logger::log(
                        Level::Info,
                        "module-otel-enrich/map",
                        &format!("'{key}' found in state store with value '{stringify}'"),
                    );
                    // Add the key-value pair to user_properties_vec
                    user_properties_vec.push((
                        BufferOrString::String(format!("otel/{key}")),
                        BufferOrString::String(stringify),
                    ));
                }
                Ok(None) => {
                    logger::log(
                        Level::Info,
                        "module-otel-enrich/map",
                        &format!("'{key}' not found in state store, skipping"),
                    );
                    continue; // Skip if key not found
                }
                Err(err) => {
                    logger::log(
                        Level::Error,
                        "module-otel-enrich/map",
                        &format!("Failed to get value for key '{key}': {err}"),
                    );
                    continue; // Skip if error occurs
                }
            }
        }

        result.topic = BufferOrBytes::Bytes("sensors".as_bytes().to_vec());
        result.properties.user_properties = user_properties_vec;

        logger::log(
            Level::Info,
            "module-otel-enrich/map",
            &format!("result: {result:?}"),
        );

        Ok(DataModel::Message(result))
    }
}