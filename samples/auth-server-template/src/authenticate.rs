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
#[serde(tag = "type", rename_all = "camelCase")]
enum ClientAuthRequest {
    /// Data from an MQTT CONNECT packet.
    #[serde(alias = "connect", rename_all = "camelCase")]
    Connect {
        /// Username, if provided.
        username: Option<String>,

        /// Password, if provided.
        password: Option<String>,

        /// Client certificate chain, if provided.
        #[serde(default, deserialize_with = "deserialize_cert_chain")]
        certs: Option<Vec<X509>>,

        /// Enhanced authentication data, if provided.
        enhanced_authentication: Option<EnhancedAuthentication>,
    },

    #[serde(alias = "auth", rename_all = "camelCase")]
    Auth {
        /// Enhanced authentication data, if provided.
        enhanced_authentication: EnhancedAuthentication,
    },
}

/// Fields from MQTT v5 enhanced authentication.
#[derive(Debug, serde::Deserialize)]
struct EnhancedAuthentication {
    /// Enhanced authentication method.
    method: String,

    /// Enhanced authentication data.
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<String>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    expiry: Option<String>,

    /// The client's authorization attributes.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
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
            enhanced_authentication,
        } => {
            // TODO: Authenticate the client with provided credentials. For now, this template just logs the
            // credentials. Note that password and enhanced authentication data are base64-encoded.
            println!("Got MQTT CONNECT; username: {username:?}, password: {password:?}, enhancedAuthentication: {enhanced_authentication:?}");

            // TODO: Authenticate the client with provided certs. For now, this template just logs the certs.
            if let Some(certs) = certs {
                println!("Got certs:");
                println!("{certs:#?}");
            }

            // TODO: Get attributes associated with the presented certificate. For now, this template
            // just provides hardcoded example values.
            let mut example_attributes = BTreeMap::new();
            example_attributes.insert("example_key".to_string(), "example_value".to_string());

            authentication_example(username.as_deref(), example_attributes)
        }

        ClientAuthRequest::Auth {
            enhanced_authentication,
        } => {
            // TODO: Authenticate the client with provided credentials. For now, this template just logs the
            // credentials. Note that password and enhanced authentication data are base64-encoded.
            println!("Got MQTT AUTH; enhancedAuthentication: {enhanced_authentication:?}");

            // Decode enhanced authentication method as 'username'.
            let engine = base64::engine::general_purpose::STANDARD;
            let method = enhanced_authentication.method;

            if let Ok(username) = base64::Engine::decode(&engine, method) {
                if let Ok(username) = std::str::from_utf8(&username) {
                    println!("Decoded enhanced authentication method: {username}");

                    // Enhanced authentication data is not used in this example, so silence the
                    // unused field warning.
                    let _ = enhanced_authentication.data;

                    authentication_example(Some(username), BTreeMap::new())
                } else {
                    ClientAuthResponse::Deny { reason: 135 }
                }
            } else {
                println!("Failed to decode enhanced authentication method");

                ClientAuthResponse::Deny { reason: 135 }
            }
        }
    }
}

fn authentication_example(
    username: Option<&str>,
    attributes: BTreeMap<String, String>,
) -> ClientAuthResponse {
    // TODO: Determine when the client's credentials should expire. For now, this template sets
    // an expiry of 10 seconds if the username starts with 'expire'; otherwise, it does not set
    // expiry and allows clients to remain connected indefinitely.
    let example_expiry = username.and_then(|username| {
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
        attributes,
    })
}
