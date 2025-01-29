// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use serde::Deserialize;
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

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

#[derive(Clone)]
pub(crate) struct StoredCredentials {
    pub credential_file: PathBuf,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ExternalAuthenticationResult {
    /// The provided credentials passed authentication.    
    Pass {
        expiry: ExpiryTime,
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

/// Expiry time of credentials, represented as a UNIX timestamp.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExpiryTime(u64);

impl ExpiryTime {
    pub(crate) fn never() -> Self {
        ExpiryTime(u64::MAX)
    }

    pub(crate) fn is_never(&self) -> bool {
        self.0 == u64::MAX
    }

    pub(crate) fn from_rfc3339(timestring: &str) -> Result<Self, String> {
        let datetime =
            chrono::DateTime::parse_from_rfc3339(timestring).map_err(|err| err.to_string())?;

        Ok(ExpiryTime::from(datetime.timestamp()))
    }

    pub(crate) fn to_rfc3339(self) -> String {
        // This function will not be called for credentials that do not expire.
        assert!(!self.is_never());

        let datetime = chrono::DateTime::from_timestamp(self.into(), 0)
            .expect("timestamp should be valid")
            .with_timezone(&chrono::Utc);

        datetime.to_rfc3339()
    }

    pub(crate) fn from_unix(unix: u64) -> Self {
        ExpiryTime(unix)
    }

    pub(crate) fn to_unix(self) -> u64 {
        // This function will not be called for credentials that do not expire.
        assert!(!self.is_never());

        self.0
    }
}

impl std::fmt::Display for ExpiryTime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.is_never() {
            write!(f, "never")
        } else {
            write!(f, "{}", self.to_rfc3339())
        }
    }
}

impl From<ExpiryTime> for i64 {
    fn from(value: ExpiryTime) -> i64 {
        match value.0.try_into() {
            Ok(value) => value,
            Err(_) => i64::MAX,
        }
    }
}

impl From<i64> for ExpiryTime {
    fn from(value: i64) -> Self {
        ExpiryTime(value.try_into().expect("i64 -> u64 conversion"))
    }
}
