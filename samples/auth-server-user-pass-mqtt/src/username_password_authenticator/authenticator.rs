// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use anyhow::Result;
use std::collections::BTreeMap;
use crate::model::AuthenticationContext;
use super::ExpiryTime;

#[derive(Debug)]
pub enum AuthenticationResult {
    /// The provided credentials passed authentication.
    Pass {
        expiry: ExpiryTime,
        attributes: BTreeMap<String, String>,
    },
    // The provided credentials failed authentication.
    Fail {
        reason: AuthenticationFailReason,
        message: String,
    },
}

#[derive(Debug)]
pub enum  AuthenticationFailReason {
    IncorrectPassword,
    UnknownUser,
}

/// A trait to authenticate a MQTT client with given credentials.
pub trait Authenticator {
    /// Authenticates a MQTT client with given credentials.    
    fn authenticate(&self, context: AuthenticationContext) -> Result<AuthenticationResult>;
}
