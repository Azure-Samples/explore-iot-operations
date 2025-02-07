// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use serde::Deserialize;
use serde::Serialize;
use std::collections::BTreeMap;

// MQTT client authentication request, contains the information from a CONNECT MQTT packet.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub(crate) enum ClientAuthRequest {
    // Data from an MQTT Connect packet.
    #[serde(alias = "connect", rename_all = "camelCase")]
    Connect {
        username: String,
        password: String,
    },

    // TODO: Support for AUTH MQTT packet
    Auth,
}

#[derive(Clone, Debug)]
pub(crate) struct AuthenticationContext {
    pub address: Option<std::net::SocketAddr>,
    pub username: String,
    pub password: Vec<u8>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ExternalAuthenticationResult {
    /// The provided credentials passed authentication.    
    Pass {
        attributes: BTreeMap<String, String>,
    },
    // The provided credentials failed authentication.    
    Fail {
        reason: ExternalFailReason,
        message: String,
    },
    // The provided credentials caused an error during authentication.    
    Error {
        error: String,
    },
    // The client requested an unsupported API version.    
    UnsupportedVersion {
        supported_versions: Vec<String>,
    },
}

#[derive(Debug, Copy, Clone, Serialize)]
#[serde(rename_all = "camelCase", into = "i32")]
pub(crate) enum ExternalFailReason {
    IncorrectPassword,
    UnknownUser,
}

impl Into<i32> for ExternalFailReason {
    fn into(self) -> i32 {
        match self {
            ExternalFailReason::IncorrectPassword => 5,
            ExternalFailReason::UnknownUser => 0,
        }
    }
}
