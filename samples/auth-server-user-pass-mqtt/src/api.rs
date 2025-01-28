// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use crate::{
    model::{
        AuthenticationContext, ClientAuthRequest, ExternalAuthenticationResult, ExternalFailReason,
    },
    username_password_authenticator::authenticator::{
        AuthenticationFailReason, AuthenticationResult, Authenticator,
    },
};
use actix_web::{
    body::BoxBody,
    http::StatusCode,
    web::{self},
    HttpRequest, HttpResponse, ResponseError,
};
use anyhow::Result;
use log::{error, trace};
use openssl::base64;
use serde::Deserialize;
use std::{
    fmt::{Display, Formatter},
    sync::Arc,
};
pub(crate) const API_SUPPORTED_VERSION: &str = "0.5.0";

pub async fn authenticate<T: Authenticator>(
    authenticator: web::Data<Arc<T>>,
    auth_query: web::Query<ApiVersion>,
    auth_data: web::Json<ClientAuthRequest>,
    request: HttpRequest,
) -> Result<HttpResponse, UnhandledError> {
    let external_authentication_result: ExternalAuthenticationResult;

    // Check for supported API version
    if auth_query.api_version != API_SUPPORTED_VERSION {
        external_authentication_result = ExternalAuthenticationResult::UnsupportedVersion {
            supported_versions: SupportedApiVersions::default().supported_versions,
        };
    } else {
        // Deserialize the request and match the request type (Connect method only for now, Auth method support will added later).
        match auth_data.into_inner() {
            ClientAuthRequest::Connect { username, password } => {
                // Abstract internal authentication result from external authentication result for security reasons.
                // Decode Base64 encoded password
                match base64::decode_block(&password) {
                    Ok(decoded_password) => {
                        match authenticator.authenticate(AuthenticationContext {
                            address: request.peer_addr(),
                            username: username,
                            password: decoded_password,
                        }) {
                            Ok(result) => {
                                trace!("Internal Authentication Result: {result:#?}");
                                external_authentication_result = match result {
                                    AuthenticationResult::Pass { expiry, attributes } => {
                                        ExternalAuthenticationResult::Pass {
                                            expiry,
                                            attributes: attributes,
                                        }
                                    }
                                    AuthenticationResult::Fail { reason, message } => {
                                        match reason {
                                            AuthenticationFailReason::IncorrectPassword => {
                                                ExternalAuthenticationResult::Fail {
                                                    reason: ExternalFailReason::IncorrectPassword,
                                                    message: message,
                                                }
                                            }
                                            AuthenticationFailReason::UnknownUser => {
                                                ExternalAuthenticationResult::Fail {
                                                    reason: ExternalFailReason::UnknownUser,
                                                    message: message,
                                                }
                                            }
                                        }
                                    }
                                };
                            }
                            Err(err) => {
                                // Log the internal error raised by authenticator details and return generic error message for security reasons.
                                error!("Error occurred during authentication: {}", err);
                                external_authentication_result =
                                    ExternalAuthenticationResult::Error {
                                        error: "Error occurred during authentication.".to_string(),
                                    };
                            }
                        }
                    }
                    Err(err) => {
                        // Log the base64 decode error details and return generic error message for security reasons.
                        error!("Error occurred during authentication: {}", err);
                        external_authentication_result = ExternalAuthenticationResult::Error {
                            error: "Error occurred during authentication.".to_string(),
                        };
                    }
                };

                trace!("External Authentication Result: {external_authentication_result:#?}");
            }
            ClientAuthRequest::Auth => {
                external_authentication_result = ExternalAuthenticationResult::Error {
                    error: "Authentication method 'Auth' is not supported, only 'Connect' is."
                        .to_string(),
                };
            }
        }
    }

    // ExternalAuthenticationResult to/and Http Response Mappings
    // TODO: we can improve this mapping to reduce manual field assignments for ExternalAuthenticationResult
    match external_authentication_result {
        // The provided credentials passed authentication.
        ExternalAuthenticationResult::Pass { expiry, attributes } => {
            if expiry.is_never() {
                return Ok(HttpResponse::Ok().json(serde_json::json!({
                    "attributes": attributes.clone(),
                })));
            } else {
                Ok(HttpResponse::Ok().json(serde_json::json!({
                    "expiry": format!("{}", expiry),
                    "attributes": attributes.clone(),
                })))
            }
        }
        // The client requested an unsupported API version.
        ExternalAuthenticationResult::UnsupportedVersion { supported_versions } => {
            Ok(HttpResponse::UnprocessableEntity()
                .json(serde_json::json!({"supportedVersions": supported_versions})))
        }
        // The provided credentials failed username password validation.
        ExternalAuthenticationResult::Fail { reason, message } => match reason {
            // Credentials failed due to incorrect password.
            ExternalFailReason::IncorrectPassword => Ok(HttpResponse::Forbidden()
                .json(serde_json::json!({ "reason": reason, "message": message }))),
            // Username not found in the password database
            ExternalFailReason::UnknownUser => Ok(HttpResponse::Forbidden().json(
                // TODO: this should return HTTP status which should allow MQTT broker to move to next authentication method in the chain.
                serde_json::json!({ "reason": reason, "message": message }),
            )),
        },
        // The provided credentials caused an error during authentication.
        ExternalAuthenticationResult::Error { error } => {
            error!("Error occurred during authentication: {}", error);
            Ok(HttpResponse::BadRequest().json(
                serde_json::json!({"error": "Error occurred during authentication.".to_string()}),
            ))
        }
    }
}

// UnhandledError is a custom error type that wraps an anyhow::Error and implements the ResponseError trait.
#[derive(Debug)]
pub struct UnhandledError {
    err: anyhow::Error,
}

impl Display for UnhandledError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.err)
    }
}

impl ResponseError for UnhandledError {
    fn status_code(&self) -> StatusCode {
        StatusCode::INTERNAL_SERVER_ERROR
    }

    fn error_response(&self) -> HttpResponse<BoxBody> {
        HttpResponse::InternalServerError().body(BoxBody::new(self.err.to_string()))
    }
}

impl From<anyhow::Error> for UnhandledError {
    fn from(err: anyhow::Error) -> UnhandledError {
        UnhandledError { err }
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "ApiVersion", rename_all = "camelCase")]
pub(crate) struct ApiVersion {
    #[serde(alias = "api-version")]
    pub api_version: String,
}

/// Returned when the client requests an invalid API version. Contains a list of
/// supported API versions.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SupportedApiVersions {
    /// List of supported API versions.
    pub supported_versions: Vec<String>,
}

impl Default for SupportedApiVersions {
    fn default() -> Self {
        SupportedApiVersions {
            supported_versions: vec![API_SUPPORTED_VERSION.to_string()],
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::model::ExpiryTime;

    use super::*;
    use mockall::predicate::*;
    use mockall::*;

    #[actix_web::test]
    async fn test_authenticate_success() {
        mock! {
            pub UsernamePasswordAuthenticator {}

            impl Authenticator for UsernamePasswordAuthenticator {
                fn authenticate(
                    &self,
                    context: AuthenticationContext,
                ) ->  Result<AuthenticationResult>;
            }
        }

        let mut mock_authenticator = MockUsernamePasswordAuthenticator::new();
        mock_authenticator
            .expect_authenticate()
            .withf(|context| {
                context.username == "test_user" && context.password == b"test_password"
            })
            .returning(|_| {
                Ok(AuthenticationResult::Pass {
                    expiry: ExpiryTime::never(),
                    attributes: {
                        let mut attributes = std::collections::BTreeMap::new();
                        attributes.insert("role".to_string(), "admin".to_string());
                        attributes.insert("department".to_string(), "engineering".to_string());
                        attributes
                    },
                })
            });

        let mock_authenticator_web_data = web::Data::new(Arc::new(mock_authenticator));

        let auth_query = web::Query(ApiVersion {
            api_version: API_SUPPORTED_VERSION.to_string(),
        });

        let auth_data = web::Json(ClientAuthRequest::Connect {
            username: "test_user".to_string(),
            password: base64::encode_block("test_password".as_bytes()),
        });

        let req = actix_web::test::TestRequest::default().to_http_request();

        let resp = authenticate(mock_authenticator_web_data, auth_query, auth_data, req)
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        let body = resp.into_body();
        let body_bytes = actix_web::body::to_bytes(body).await.unwrap();
        let body_json: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap();

        assert!(!body_json.get("expiry").is_some());
        assert_eq!(body_json["attributes"]["role"], serde_json::json!("admin"));
        assert_eq!(
            body_json["attributes"]["department"],
            serde_json::json!("engineering")
        );
    }

    #[actix_web::test]
    async fn test_authenticate_incorrect_password_fail() {
        mock! {
            pub UsernamePasswordAuthenticator {}

            impl Authenticator for UsernamePasswordAuthenticator {
                fn authenticate(
                    &self,
                    context: AuthenticationContext,
                ) ->  Result<AuthenticationResult>;
            }
        }

        let mut mock_authenticator = MockUsernamePasswordAuthenticator::new();
        mock_authenticator
            .expect_authenticate()
            .withf(|context| {
                context.username == "test_user" && context.password == b"test_password"
            })
            .returning(|_| {
                Ok(AuthenticationResult::Fail {
                    reason: AuthenticationFailReason::IncorrectPassword,
                    message: "Authentication failed.".to_string(),
                })
            });

        let mock_authenticator_web_data = web::Data::new(Arc::new(mock_authenticator));

        let auth_query = web::Query(ApiVersion {
            api_version: API_SUPPORTED_VERSION.to_string(),
        });

        let auth_data = web::Json(ClientAuthRequest::Connect {
            username: "test_user".to_string(),
            password: base64::encode_block("test_password".as_bytes()),
        });

        let req = actix_web::test::TestRequest::default().to_http_request();

        let resp = authenticate(mock_authenticator_web_data, auth_query, auth_data, req)
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        let body = resp.into_body();
        let body_bytes = actix_web::body::to_bytes(body).await.unwrap();
        let body_json: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap();

        assert_eq!(body_json["reason"], serde_json::json!(5));
        assert_eq!(
            body_json["message"],
            serde_json::json!("Authentication failed.")
        );
    }

    #[actix_web::test]
    async fn test_authenticate_unknown_username_fail() {
        mock! {
            pub UsernamePasswordAuthenticator {}

            impl Authenticator for UsernamePasswordAuthenticator {
                fn authenticate(
                    &self,
                    context: AuthenticationContext,
                ) ->  Result<AuthenticationResult>;
            }
        }

        let mut mock_authenticator = MockUsernamePasswordAuthenticator::new();
        mock_authenticator
            .expect_authenticate()
            .withf(|context| {
                context.username == "test_user" && context.password == b"test_password"
            })
            .returning(|_| {
                Ok(AuthenticationResult::Fail {
                    reason: AuthenticationFailReason::UnknownUser,
                    message: "Authentication failed.".to_string(),
                })
            });

        let mock_authenticator_web_data = web::Data::new(Arc::new(mock_authenticator));

        let auth_query = web::Query(ApiVersion {
            api_version: API_SUPPORTED_VERSION.to_string(),
        });

        let auth_data = web::Json(ClientAuthRequest::Connect {
            username: "test_user".to_string(),
            password: base64::encode_block("test_password".as_bytes()),
        });

        let req = actix_web::test::TestRequest::default().to_http_request();

        let resp = authenticate(mock_authenticator_web_data, auth_query, auth_data, req)
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        let body = resp.into_body();
        let body_bytes = actix_web::body::to_bytes(body).await.unwrap();
        let body_json: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap();

        assert_eq!(body_json["reason"], serde_json::json!(0));
        assert_eq!(
            body_json["message"],
            serde_json::json!("Authentication failed.")
        );
    }

    #[actix_web::test]
    async fn test_authenticate_unsupported_version() {
        mock! {
            pub UsernamePasswordAuthenticator {}

            impl Authenticator for UsernamePasswordAuthenticator {
                fn authenticate(
                    &self,
                    context: AuthenticationContext,
                ) ->  Result<AuthenticationResult>;
            }
        }

        let auth_query = web::Query(ApiVersion {
            api_version: "0.4.0".to_string(),
        });
        let mock_authenticator = MockUsernamePasswordAuthenticator::new();
        let mock_authenticator_web_data = web::Data::new(Arc::new(mock_authenticator));

        let auth_data = web::Json(ClientAuthRequest::Connect {
            username: "test_user".to_string(),
            password: base64::encode_block("test_password".as_bytes()),
        });

        let req = actix_web::test::TestRequest::default().to_http_request();

        let resp = authenticate(mock_authenticator_web_data, auth_query, auth_data, req)
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let body = resp.into_body();
        let body_bytes = actix_web::body::to_bytes(body).await.unwrap();
        let body_json: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(body_json["supportedVersions"], serde_json::json!(["0.5.0"]));
    }

    #[actix_web::test]
    async fn test_authenticate_error_shielding() {
        mock! {
            pub UsernamePasswordAuthenticator {}

            impl Authenticator for UsernamePasswordAuthenticator {
                fn authenticate(
                    &self,
                    context: AuthenticationContext,
                ) ->  Result<AuthenticationResult>;
            }
        }

        let mut mock_authenticator = MockUsernamePasswordAuthenticator::new();
        mock_authenticator
            .expect_authenticate()
            .withf(|context| {
                context.username == "test_user" && context.password == b"test_password"
            })
            .returning(|_| Err(anyhow::anyhow!("Error occurred during authentication.")));

        let mock_authenticator_web_data = web::Data::new(Arc::new(mock_authenticator));

        let auth_query = web::Query(ApiVersion {
            api_version: API_SUPPORTED_VERSION.to_string(),
        });

        let auth_data = web::Json(ClientAuthRequest::Connect {
            username: "test_user".to_string(),
            password: base64::encode_block("test_password".as_bytes()),
        });

        let req = actix_web::test::TestRequest::default().to_http_request();

        let resp = authenticate(mock_authenticator_web_data, auth_query, auth_data, req)
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

        let body = resp.into_body();
        let body_bytes = actix_web::body::to_bytes(body).await.unwrap();
        let body_json: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap();        
        assert_eq!(
            body_json["error"],
            serde_json::json!("Error occurred during authentication.")
        );
    }
}
