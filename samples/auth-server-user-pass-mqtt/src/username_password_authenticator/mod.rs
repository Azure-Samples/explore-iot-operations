// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

pub mod authenticator;
pub mod watcher;

use anyhow::Result;
use authenticator::{AuthenticationFailReason, AuthenticationResult, Authenticator};
use log::{trace, warn};
use password_hash::{PasswordHashString, PasswordVerifier};
use pbkdf2::Pbkdf2;
use std::{collections::BTreeMap, path::Path};
use watcher::{FileWatcher, FileWatcherInstance};

use crate::model::{AuthenticationContext, ExpiryTime};

#[derive(Debug)]
pub struct UsernamePasswordAuthenticator {
    password_database: FileWatcherInstance<BTreeMap<String, Password>>,
}

#[derive(Clone, Debug, serde::Deserialize)]
pub struct Password {
    #[serde(alias = "password", deserialize_with = "deserialize_password_hash")]
    hash: PasswordHashString,

    #[serde(default)]
    attributes: BTreeMap<String, String>,
}

pub fn deserialize_password_hash<'de, D>(deserializer: D) -> Result<PasswordHashString, D::Error>
where
    D: serde::de::Deserializer<'de>,
{
    let hash: String = serde::Deserialize::deserialize(deserializer)?;

    PasswordHashString::new(&hash).map_err(|_| serde::de::Error::custom("bad password hash"))
}

impl UsernamePasswordAuthenticator {
    pub fn new(config: &Path) -> Result<UsernamePasswordAuthenticator> {
        let parser = Box::new(|path: &std::path::Path| {
            let password_database = std::fs::read_to_string(path)?;
            let password_database: BTreeMap<String, Password> =
                toml::de::from_str(&password_database)?;
            Ok(password_database)
        });

        let password_database = FileWatcher::new(config, parser, None)?;

        Ok(UsernamePasswordAuthenticator { password_database })
    }
}

impl Authenticator for UsernamePasswordAuthenticator {
    fn authenticate(&self, context: AuthenticationContext) -> Result<AuthenticationResult> {
        let (username, password) = (context.username, context.password);
        let password_database = self.password_database.contents.read();

        trace!(
            "Password database loaded, authenticating user: {}",
            username
        );

        if let Some(stored_credential) = password_database.get(&username) {
            if let Err(err) =
                Pbkdf2.verify_password(&password, &stored_credential.hash.password_hash())
            {
                match err {
                    password_hash::Error::Password => {
                        return Ok(AuthenticationResult::Fail {
                            reason: AuthenticationFailReason::IncorrectPassword,
                            message: "Authentication failed.".to_string(),
                        });
                    }
                    _ => {
                        return Err(anyhow::anyhow!("Password verification error: {:?}", err));
                    }
                }
            }

            Ok(AuthenticationResult::Pass {
                attributes: stored_credential.attributes.clone(),
                expiry: ExpiryTime::never(),
            })
        } else {
            // The provided username is not present in the password database, but may
            // still be acceptable for one of the other auth methods.
            return Ok(AuthenticationResult::Fail {
                reason: AuthenticationFailReason::UnknownUser,
                message: "Username not found in database.".to_string(),
            });
        }
    }
}
