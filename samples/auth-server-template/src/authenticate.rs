// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use std::collections::BTreeMap;

use hyper::{header, Method, StatusCode};
use openssl::x509::X509;

use crate::http::{ParsedRequest, Response};

/// Returned when the client requests an invalid API version. Contains a list of
/// supported API versions.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct SupportedApiVersions {
    /// List of supported API versions.
    supported_versions: Vec<String>,
}

impl Default for SupportedApiVersions {
    fn default() -> Self {
        SupportedApiVersions {
            supported_versions: vec!["0.5.0".to_string()],
        }
    }
}

/// Authenticate the connecting MQTT client.
pub(crate) async fn authenticate(req: ParsedRequest) -> Response {
    // Check that the request follows the authentication spec.
    if req.method != Method::POST {
        return Response::method_not_allowed(&req.method);
    }

    if let Some(content_type) = req.headers.get(header::CONTENT_TYPE.as_str()) {
        if content_type.to_lowercase() != "application/json" {
            return Response::bad_request(format!("invalid content-type: {content_type}"));
        }
    }

    let Some(body) = req.body else {
        return Response::bad_request("missing body");
    };

    if req.path != "/" {
        return Response::not_found(format!("{} not found", req.path));
    }

    if let Some(api_version) = req.query.get("api-version") {
        // Currently, the custom auth API supports only version 0.5.0.
        if api_version != "0.5.0" {
            return Response::json(
                StatusCode::UNPROCESSABLE_ENTITY,
                SupportedApiVersions::default(),
            );
        }
    } else {
        return Response::bad_request("missing api-version");
    }

    let body: ClientAuthRequest = match serde_json::from_str(&body) {
        Ok(body) => body,
        Err(err) => return Response::bad_request(format!("invalid client request body: {err}")),
    };

    Response::from(auth_client(body).await)
}

/// MQTT client authentication request. Contains the information from either a CONNECT
/// or AUTH packet.
#[derive(Debug, serde::Deserialize)]
#[serde(tag = "type")]
enum ClientAuthRequest {
    /// Data from an MQTT CONNECT packet.
    #[serde(alias = "connect")]
    Connect {
        /// Username, if provided.
        username: Option<String>,

        /// Password, if provided.
        password: Option<String>,

        /// Client certificate chain, if provided.
        #[serde(default, deserialize_with = "deserialize_cert_chain")]
        certs: Option<Vec<X509>>,
    },
}

fn deserialize_cert_chain<'de, D>(deserializer: D) -> Result<Option<Vec<X509>>, D::Error>
where
    D: serde::de::Deserializer<'de>,
{
    let certs: Option<String> = serde::Deserialize::deserialize(deserializer)?;

    if let Some(certs) = certs {
        let certs = X509::stack_from_pem(certs.as_bytes()).map_err(|err| {
            serde::de::Error::invalid_type(
                serde::de::Unexpected::Other(&err.to_string()),
                &"pem-encoded cert",
            )
        })?;

        Ok(Some(certs))
    } else {
        Ok(None)
    }
}

enum ClientAuthResponse {
    /// Allow the connection. Translates to a CONNACK packet with reason = success.
    Allow(AuthPassResponse),

    /// Deny the connection. Translates to a CONNACK packet with the given reason code.
    Deny { reason: u8 },
}

/// Response to an authenticated client.
#[derive(Debug, serde::Serialize)]
struct AuthPassResponse {
    /// RFC 3339 timestamp that states the expiry time for the client's
    /// provided credentials. Clients will be disconnected when the expiry time passes.
    /// Omit `expiry` to allow clients to remain connected indefinitely.
    expiry: Option<String>,

    /// The client's authorization attributes. The response must contain
    /// a body, so pass an empty map if there are no authorization attributes.
    attributes: BTreeMap<String, String>,
}

impl From<ClientAuthResponse> for Response {
    fn from(response: ClientAuthResponse) -> Response {
        match response {
            ClientAuthResponse::Allow(response) => Response::json(StatusCode::OK, response),

            ClientAuthResponse::Deny { reason } => {
                let body = serde_json::json!({
                    "reason": reason,
                });

                Response::json(StatusCode::FORBIDDEN, body)
            }
        }
    }
}

// This implementation is a placeholder. The actual implementation may need to be async, so allow unused async
// in the signature.
#[allow(clippy::unused_async)]
async fn auth_client(body: ClientAuthRequest) -> ClientAuthResponse {
    match body {
        ClientAuthRequest::Connect {
            username,
            password,
            certs,
        } => {
            // TODO: Authenticate the client with provided credentials. For now, this template just logs the
            // credentials. Note the password is base64-encoded.
            println!("Got MQTT CONNECT; username: {username:?}, password: {password:?}");

            // TODO: Authenticate the client with provided certs. For now, this template just logs the certs.
            if let Some(certs) = certs {
                println!("Got certs:");
                println!("{certs:#?}");
            }

            // TODO: Get attributes associated with the presented certificate. For now, this template
            // just provides hardcoded example values.
            let mut example_attributes = BTreeMap::new();
            example_attributes.insert("example_key".to_string(), "example_value".to_string());

            // TODO: Determine when the client's credentials should expire. For now, this template sets
            // an expiry of 10 seconds if the username starts with 'expire'; otherwise, it does not set
            // expiry and allows clients to remain connected indefinitely.
            let example_expiry = username.as_ref().and_then(|username| {
                if username.starts_with("expire") {
                    let example_expiry = chrono::Utc::now()
                        + chrono::TimeDelta::try_seconds(10).expect("invalid hardcoded time value");

                    Some(example_expiry.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
                } else {
                    None
                }
            });

            // Example responses to client authentication. This template denies authentication to clients
            // who present usernames that begin with 'deny', but allows all others.
            if let Some(username) = username {
                if username.starts_with("deny") {
                    return ClientAuthResponse::Deny { reason: 135 };
                }
            }

            ClientAuthResponse::Allow(AuthPassResponse {
                expiry: example_expiry,
                attributes: example_attributes,
            })
        }
    }
}
