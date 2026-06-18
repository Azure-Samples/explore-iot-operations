mod filter_operator {
#![allow(clippy::missing_safety_doc)]

    use jsonschema::JSONSchema;
    use serde_json::Value;
    use wasm_graph_sdk::logger::{self, Level};
    use wasm_graph_sdk::macros::filter_operator;

    use once_cell::sync::Lazy;
    use std::sync::Mutex;

    static SCHEMA: Lazy<Mutex<Option<JSONSchema<'static>>>> = Lazy::new(|| Mutex::new(None));
    
    // set up the schema provided by the developer
    fn filter_init(configuration: ModuleConfiguration) -> bool {
        logger::log(
            Level::Info,
            "filter",
            "Initialization function invoked",
        );

        for (key, value) in configuration.properties {
            logger::log(
                Level::Info,
                "filter",
                &format!("Initialization received the property (key='{key}', value='{value}')."),
            );
        }

        if configuration.module_schemas.len() == 0 {
            logger::log(
                Level::Error,
                "filter",
                "Initialization received no schemas.",
            );
            return false;
        }

        if configuration.module_schemas.len() > 1 {
            logger::log(
                Level::Warn,
                "filter",
                "Initialization received multiple schemas, only the first will be used.",
            );
        }

        let module_schema = &configuration.module_schemas[0];
        logger::log(
            Level::Info,
            "filter",
            &format!("Initialization received the schema '{module_schema:?}'."),
        );
        let schema_json: Value = serde_json::from_str(&module_schema.content).unwrap();

        // Convert schema_json to have a 'static lifetime
        let schema_json_static: &'static Value = Box::leak(Box::new(schema_json));

        // Compile the schema and cache it directly
        let mut cached_schema = SCHEMA.lock().unwrap();
        *cached_schema = Some(JSONSchema::compile(schema_json_static).unwrap());

        true
    }


    #[filter_operator(init = "filter_init")]
    // validate the input against the schema
    fn filter(input: DataModel) -> Result<bool, Error> {
        let DataModel::Message(message) = input else {
            return Err(Error { message: "Unexpected input type".to_string() });
        };

        let result = Message {
            timestamp: message.timestamp,
            topic: BufferOrBytes::Bytes(b"sensors"[..].to_owned()),
            payload: message.payload,
            properties: message.properties,
            content_type: None,
            schema: None,
        };

        // Check if the schema is already cached
        let cached_schema = SCHEMA.lock().unwrap();
        if cached_schema.is_none() {
            logger::log(Level::Warn, "filter", "Schema not found");
            return Ok(false);
        }
        logger::log(
            Level::Info,
            "filter",
            &format!("cached_schema is: {cached_schema:?}"),
        );
        // Use the cached schema for validation
        let compiled_schema = cached_schema.as_ref().unwrap();
        let payload = &result.payload.read();
        let payload_json: Value = match serde_json::from_slice(payload) {
            Ok(v) => v,
            Err(e) => {
                logger::log(
                    Level::Error,
                    "filter",
                    &format!("Failed to parse payload as JSON: {e}"),
                );
                return Ok(false);
            }
        };

        // Validate the payload against the schema
        let validation_result = compiled_schema.validate(&payload_json);

        match validation_result {
            Ok(()) => {
                logger::log(
                    Level::Info,
                    "filter",
                    "Payload is valid according to the schema",
                );
                Ok(true)
            }
            Err(errors) => {
                for error in errors {
                    logger::log(
                        Level::Error,
                        "filter",
                        &format!("Validation error: {error}"),
                    );
                }
                Ok(false)
            }
        }
    }

}