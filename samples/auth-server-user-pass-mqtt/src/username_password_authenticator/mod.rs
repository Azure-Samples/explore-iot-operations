// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

pub(crate) mod authenticator;
pub(crate) mod watcher;

use anyhow::Result;
use authenticator::{AuthenticationFailReason, AuthenticationResult, Authenticator};
use log::trace;
use password_hash::{PasswordHashString, PasswordVerifier};
use pbkdf2::Pbkdf2;
use std::{collections::BTreeMap, path::Path};
use watcher::{FileWatcher, FileWatcherInstance};

use crate::model::{AuthenticationContext, ExpiryTime};

#[derive(Debug)]
pub(crate) struct UsernamePasswordAuthenticator {
    password_database: FileWatcherInstance<BTreeMap<String, Password>>,
}

#[derive(Clone, Debug, serde::Deserialize)]
pub(crate) struct Password {
    #[serde(alias = "password", deserialize_with = "deserialize_password_hash")]
    hash: PasswordHashString,

    #[serde(default)]
    attributes: BTreeMap<String, String>,
}

pub(crate) fn deserialize_password_hash<'de, D>(
    deserializer: D,
) -> Result<PasswordHashString, D::Error>
where
    D: serde::de::Deserializer<'de>,
{
    let hash: String = serde::Deserialize::deserialize(deserializer)?;

    PasswordHashString::new(&hash).map_err(|_| serde::de::Error::custom("bad password hash"))
}

impl UsernamePasswordAuthenticator {
    pub(crate) fn new(config: &Path) -> Result<UsernamePasswordAuthenticator> {
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

        // TODO: potentially optimize this by only reading the password database once on startup.
        let password_database = self.password_database.contents.read();

        trace!(
            "Password database loaded, authenticating user: {}, peer address: {:?}",
            username,
            context.address
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

#[cfg(test)]
mod tests {
    use crate::{
        model::AuthenticationContext,
        username_password_authenticator::{
            authenticator::AuthenticationFailReason, Authenticator, Password,
        },
    };
    use password_hash::PasswordHashString;
    use std::{collections::BTreeMap, io::Write, net::SocketAddr};

    use super::{authenticator::AuthenticationResult, UsernamePasswordAuthenticator};

    fn test_authenticator() -> UsernamePasswordAuthenticator {
        // The official guidance for Microsoft products recommends 100,000+ rounds.
        // However, 100,000 rounds produces a noticeable delay, so these test hashes
        // use 1,000 rounds to speed up testing.
        const PASSWORD_DATABASE: &str = r#"
[user1]
# salt = "wTFUK6e9EAKJz3ryC/LcFg", password = "password1"
password = "$pbkdf2-sha512$i=1000,l=64$wTFUK6e9EAKJz3ryC/LcFg$RbAignNapzgmHxLIehyKCWXioWP69kJn1X49nTd/u/UWT0Ady18jGrubKOZyHRA9KFErMDnxwJaRSmpIUk874A"

[user1.attributes]
group = "user_group"
organization = "org1"

[user2]
# salt = "TFCUfCWgpqsddWGg2UsIeA", password = "password2"
password = "$pbkdf2-sha512$i=1000,l=64$TFCUfCWgpqsddWGg2UsIeA$BPo3fKqDaLxGDwfTt1WdlJjZuiMsUGBgg97IahAU9hLIiwfHZhV+fMBAYpEejDEYfKzo86qLQ472XIuR8toQ6Q"

[user2.attributes]
group = "user_group"
organization = "org2"

[user3]
# salt = "lIR+Zxtj4e1RaOj3QvnNPg", password = "password2"
password = "$pbkdf2-sha512$i=1000,l=64$lIR+Zxtj4e1RaOj3QvnNPg$ApSUlBbZ4NiVi35KT4jx0TKHsbbsaDw72q2I482p72aru9IjWlMRr8YoPCzkXF//UB7Pi7CSDCF0vCGwUQQ7hA"
"#;

        let mut database = tempfile::NamedTempFile::new().unwrap();
        database
            .as_file_mut()
            .write_all(PASSWORD_DATABASE.as_bytes())
            .unwrap();

        UsernamePasswordAuthenticator::new(&database.path()).unwrap()
    }

    #[test]
    fn deserialize_database() {
        let authenticator = test_authenticator();

        let mut database_copy: BTreeMap<String, Password> =
            authenticator.password_database.contents.read().clone();
        let user1 = database_copy.remove("user1").unwrap();
        let user2 = database_copy.remove("user2").unwrap();
        let user3 = database_copy.remove("user3").unwrap();
        assert!(database_copy.is_empty());

        assert_eq!(
            PasswordHashString::new(
                "$pbkdf2-sha512$i=1000,l=64$wTFUK6e9EAKJz3ryC/LcFg$RbAignNapzgmHxLIehyKCWXioWP69kJn1X49nTd/u/UWT0Ady18jGrubKOZyHRA9KFErMDnxwJaRSmpIUk874A",
            )
            .unwrap(),
            user1.hash
        );
        assert_eq!(
            PasswordHashString::new(
                "$pbkdf2-sha512$i=1000,l=64$TFCUfCWgpqsddWGg2UsIeA$BPo3fKqDaLxGDwfTt1WdlJjZuiMsUGBgg97IahAU9hLIiwfHZhV+fMBAYpEejDEYfKzo86qLQ472XIuR8toQ6Q",
            )
            .unwrap(),
            user2.hash
        );
        assert_eq!(
            PasswordHashString::new(
                "$pbkdf2-sha512$i=1000,l=64$lIR+Zxtj4e1RaOj3QvnNPg$ApSUlBbZ4NiVi35KT4jx0TKHsbbsaDw72q2I482p72aru9IjWlMRr8YoPCzkXF//UB7Pi7CSDCF0vCGwUQQ7hA",
            )
            .unwrap(),
            user3.hash
        );

        assert_eq!("user_group", user1.attributes.get("group").unwrap());
        assert_eq!("user_group", user2.attributes.get("group").unwrap());
        assert_eq!("org1", user1.attributes.get("organization").unwrap());
        assert_eq!("org2", user2.attributes.get("organization").unwrap());
        assert!(user3.attributes.is_empty());
    }

    #[tokio::test]
    async fn auth_pass() {
        let authenticator = test_authenticator();

        let context = AuthenticationContext {
            address: Some(SocketAddr::from(([0, 0, 0, 0], 8883))),
            username: "user1".to_string(),
            password: b"password1".to_vec(),
        };

        match authenticator.authenticate(context).unwrap() {
            AuthenticationResult::Pass {
                mut attributes,
                expiry,
            } => {
                assert_eq!("user_group", attributes.remove("group").unwrap());
                assert_eq!("org1", attributes.remove("organization").unwrap());
                assert!(attributes.is_empty());
                assert!(expiry.is_never());
            }
            _ => panic!("incorrect result"),
        }
    }

    #[tokio::test]
    async fn auth_fail_incorrect_password() {
        let authenticator = test_authenticator();

        // Test Fail with incorrect password
        let context = AuthenticationContext {
            address: Some(SocketAddr::from(([0, 0, 0, 0], 8883))),
            username: "user1".to_string(),
            password: b"incorrect".to_vec(),
        };

        match authenticator.authenticate(context).unwrap() {
            AuthenticationResult::Fail { reason, message } => match reason {
                AuthenticationFailReason::IncorrectPassword => {
                    assert_eq!("Authentication failed.", message);
                }
                _ => panic!("incorrect result"),
            },
            _ => panic!("incorrect result"),
        }
    }

    #[tokio::test]
    async fn auth_fail_unknown_user() {
        let authenticator = test_authenticator();

        // Test Fail with incorrect password
        let context = AuthenticationContext {
            address: Some(SocketAddr::from(([0, 0, 0, 0], 8883))),
            username: "incorrect".to_string(),
            password: b"password1".to_vec(),
        };

        match authenticator.authenticate(context).unwrap() {
            AuthenticationResult::Fail { reason, message } => match reason {
                AuthenticationFailReason::UnknownUser => {
                    assert_eq!("Username not found in database.", message);
                }
                _ => panic!("incorrect result"),
            },
            _ => panic!("incorrect result"),
        }
    }
}
