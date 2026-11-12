// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashSet, VecDeque};

#[cfg(any(
    all(feature = "get-status", feature = "continuous-move"),
    all(feature = "get-status", feature = "stop"),
    all(feature = "continuous-move", feature = "stop")
))]
compile_error!("Build each camera action separately");
#[cfg(all(
    target_arch = "wasm32",
    not(any(feature = "get-status", feature = "continuous-move", feature = "stop"))
))]
compile_error!("Select one camera action feature");
#[cfg(target_arch = "wasm32")]
mod operator;

pub const MAX_BYTES: usize = 65536;
pub const LEDGER_SIZE: usize = 1024;

pub struct Settings {
    pub asset_name: String,
    pub profile_token: String,
}

impl Settings {
    pub fn from_properties(properties: &[(String, String)]) -> Result<Self, String> {
        let mut asset = None;
        let mut profile = None;
        for (key, value) in properties {
            match key.as_str() {
                "asset_name" if asset.is_none() => asset = Some(value.clone()),
                "profile_token" if profile.is_none() => profile = Some(value.clone()),
                _ => return Err(format!("Unknown or duplicate camera setting: {key}")),
            }
        }
        let asset_name = asset.ok_or("asset_name is required")?;
        let profile_token = profile.ok_or("profile_token is required")?;
        if asset_name.is_empty()
            || asset_name.len() > 63
            || !asset_name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            || asset_name.starts_with('-')
            || asset_name.ends_with('-')
            || profile_token.is_empty()
            || profile_token.len() > 128
            || !profile_token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err("Invalid configured Asset name or profile token".into());
        }
        Ok(Self {
            asset_name,
            profile_token,
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub request_id: String,
    pub issued_at: f64,
    pub action: String,
    pub payload: Value,
}

#[derive(Default)]
pub struct Ledger {
    ids: HashSet<String>,
    order: VecDeque<String>,
}

impl Ledger {
    pub fn claim(&mut self, id: &str) -> bool {
        if !self.ids.insert(id.into()) {
            return false;
        }
        self.order.push_back(id.into());
        if self.order.len() > LEDGER_SIZE {
            if let Some(oldest) = self.order.pop_front() {
                self.ids.remove(&oldest);
            }
        }
        true
    }
}

fn exact_keys(value: &Value, keys: &[&str]) -> bool {
    value.as_object().is_some_and(|object| {
        object.len() == keys.len() && keys.iter().all(|key| object.contains_key(*key))
    })
}

pub fn decode(bytes: &[u8]) -> Result<Request, String> {
    if bytes.len() > MAX_BYTES {
        return Err("Request exceeds 64 KiB".into());
    }
    serde_json::from_slice(bytes).map_err(|error| format!("Invalid request JSON: {error}"))
}

pub fn validate(
    request: &Request,
    action: &str,
    now: f64,
    settings: &Settings,
) -> Result<(), String> {
    if request.request_id.len() != 32
        || !request
            .request_id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("requestId must be 32 lowercase hexadecimal characters".into());
    }
    if !now.is_finite()
        || !request.issued_at.is_finite()
        || now - request.issued_at
            > if action == "ContinuousMove" {
                5.0
            } else {
                10.0
            }
        || request.issued_at - now > 5.0
    {
        return Err("Request is stale or issuedAt is invalid".into());
    }
    if request.action != action || !exact_keys(&request.payload, &[action]) {
        return Err("Action does not match this graph or payload wrapper".into());
    }
    let body = &request.payload[action];
    if body["ProfileToken"] != settings.profile_token {
        return Err("Profile does not match the configured camera".into());
    }
    let valid = match action {
        "GetStatus" => exact_keys(body, &["ProfileToken"]),
        "Stop" => {
            exact_keys(body, &["ProfileToken", "PanTilt", "Zoom"])
                && body["PanTilt"] == true
                && body["Zoom"] == false
        }
        "ContinuousMove" => {
            let velocity = &body["Velocity"];
            let pan_tilt = &velocity["PanTilt"];
            let pan = pan_tilt["x"].as_f64().unwrap_or(f64::NAN);
            let duration = body["Timeout"]
                .as_str()
                .and_then(|value| value.strip_prefix("PT"))
                .and_then(|value| value.strip_suffix('S'))
                .and_then(|value| value.parse::<u32>().ok());
            exact_keys(body, &["ProfileToken", "Velocity", "Timeout"])
                && exact_keys(velocity, &["PanTilt"])
                && exact_keys(pan_tilt, &["x", "y"])
                && pan_tilt["y"].as_f64() == Some(0.0)
                && pan.is_finite()
                && pan.abs() == 0.35
                && duration
                    .is_some_and(|n| (1..=6).contains(&n) && body["Timeout"] == format!("PT{n}S"))
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err("Invalid action payload or movement bounds".into())
    }
}

pub fn result(
    request: &Request,
    completed: f64,
    response: Result<Value, String>,
    settings: &Settings,
) -> Value {
    let (response, error) = match response {
        Ok(value) if value.is_object() => (value, Value::Null),
        Ok(_) => (
            Value::Null,
            json!("ONVIF managed-action RPC response is not a JSON object"),
        ),
        Err(error) => (Value::Null, json!(error)),
    };
    json!({
        "type":"camera-action-result", "requestId":request.request_id,
        "action":request.action, "assetName":settings.asset_name,
        "profileToken":settings.profile_token, "issuedAt":request.issued_at,
        "completedAt":completed, "response":response, "error":error
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings() -> Settings {
        Settings::from_properties(&[
            ("asset_name".into(), "camera-control".into()),
            ("profile_token".into(), "profile_high".into()),
        ])
        .unwrap()
    }

    fn request(action: &str, body: Value) -> Request {
        decode(
            &serde_json::to_vec(&json!({
                "requestId":"0123456789abcdef0123456789abcdef",
                "issuedAt":100, "action":action, "payload":{action:body}
            }))
            .unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn fixed_target_and_strict_input() {
        assert!(Settings::from_properties(&[]).is_err());
        assert!(Settings::from_properties(&[
            ("asset_name".into(), "other/PTZ".into()),
            ("profile_token".into(), "profile_high".into()),
        ])
        .is_err());
        let mut r = request("GetStatus", json!({"ProfileToken":"profile_high"}));
        assert!(validate(&r, "GetStatus", 110.0, &settings()).is_ok());
        assert!(validate(&r, "GetStatus", 110.01, &settings()).is_err());
        assert!(validate(&r, "GetStatus", 94.9, &settings()).is_err());
        assert!(validate(&r, "Stop", 100.0, &settings()).is_err());
        r.payload["GetStatus"]["ProfileToken"] = json!("other");
        assert!(validate(&r, "GetStatus", 100.0, &settings()).is_err());
        assert!(decode(&vec![b' '; MAX_BYTES + 1]).is_err());
        assert!(decode(
            br#"{"requestId":"a","issuedAt":1,"action":"Stop","payload":{},"extra":1}"#
        )
        .is_err());
    }

    #[test]
    fn bounded_finite_movement() {
        for speed in [-0.35, 0.35] {
            for duration in [1, 6] {
                let r = request(
                    "ContinuousMove",
                    json!({
                        "ProfileToken":"profile_high", "Velocity":{"PanTilt":{"x":speed,"y":0}},
                        "Timeout":format!("PT{duration}S")
                    }),
                );
                assert!(validate(&r, "ContinuousMove", 105.0, &settings()).is_ok());
                assert!(validate(&r, "ContinuousMove", 105.01, &settings()).is_err());
            }
        }
        for (speed, timeout) in [
            (0.0, "PT1S"),
            (1.0, "PT1S"),
            (0.35, "PT7S"),
            (0.35, "PT01S"),
        ] {
            let r = request(
                "ContinuousMove",
                json!({
                    "ProfileToken":"profile_high", "Velocity":{"PanTilt":{"x":speed,"y":0}},
                    "Timeout":timeout
                }),
            );
            assert!(validate(&r, "ContinuousMove", 100.0, &settings()).is_err());
        }
    }

    #[test]
    fn stop_preserves_real_responses_and_errors() {
        let r = request(
            "Stop",
            json!({"ProfileToken":"profile_high","PanTilt":true,"Zoom":false}),
        );
        assert!(validate(&r, "Stop", 100.0, &settings()).is_ok());
        let native = json!({"Result":{},"nativeField":[1,2]});
        let frame = result(&r, 101.0, Ok(native.clone()), &settings());
        assert_eq!(frame["response"], native);
        assert_eq!(frame["assetName"], "camera-control");
        assert!(result(&r, 101.0, Err("timeout".into()), &settings())["response"].is_null());
        assert!(result(&r, 101.0, Ok(json!(null)), &settings())["error"].is_string());
    }

    #[test]
    fn duplicate_requests_are_not_reinvoked() {
        let mut ledger = Ledger::default();
        assert!(ledger.claim("first"));
        assert!(!ledger.claim("first"));
        for n in 0..LEDGER_SIZE {
            assert!(ledger.claim(&n.to_string()));
        }
        assert_eq!(ledger.ids.len(), LEDGER_SIZE);
        assert!(ledger.claim("first"));
    }
}
