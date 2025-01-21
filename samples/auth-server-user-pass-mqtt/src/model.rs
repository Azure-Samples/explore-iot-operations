use serde::Deserialize;

use crate::api::API_SUPPORTED_VERSION;

#[derive(Debug, Deserialize)]
#[serde(tag = "ApiVersion", rename_all = "camelCase")]
pub struct ApiVersion {    
    #[serde(alias = "api-version")]
    pub api_version: String
}

/// Returned when the client requests an invalid API version. Contains a list of
/// supported API versions.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SupportedApiVersions {
    /// List of supported API versions.
    supported_versions: Vec<String>,
}

impl Default for SupportedApiVersions {
    fn default() -> Self {
        SupportedApiVersions {
            supported_versions: vec![API_SUPPORTED_VERSION.to_string()],
        }
    }
}

/// MQTT client authentication request. Contains the information from either a CONNECT
/// or AUTH packet.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ClientAuthRequest {
    /// Data from an MQTT CONNECT packet.
    #[serde(alias = "connect", rename_all = "camelCase")]
    Connect {
        /// Username, if provided.
        username: Option<String>,

        /// Password, if provided.
        password: Option<String>,
    },
}
